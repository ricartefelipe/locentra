# frozen_string_literal: true

module Locentra
  module Application
    # Configurações da organização (nome, fuso, validade padrão do bloqueio e política de cancelamento) e
    # gestão de filiais (edição, desativação e reativação), com controle otimista (`lock_version`) e
    # auditoria na mesma transação. Prévia, restauração de padrão, salvamento sem mudança e operações
    # recusadas não gravam nem auditam.
    #
    # Ordem global de travas (docs/ISOLAMENTO.md): filial → organização (desativação); filial →
    # assinatura (reativação, cadastro de ativo e entrada de estoque); só assinatura (CreateBranch); só
    # organização (UpdateSettings). Criações ligadas a uma filial (reserva, versão e envio de orçamento,
    # transferência com destino a ela, ativo, entrada de estoque) travam a filial com FOR SHARE; a
    # desativação, com FOR NO KEY UPDATE: as duas se excluem.
    module Organizations
      Result = Data.define(:record, :changed)

      STALE_ORGANIZATION = "as configurações da organização foram alteradas por outra operação; revise os valores atuais"
      STALE_BRANCH = "a filial foi alterada por outra operação; revise os valores atuais"

      # Filial existente e ativa para uma operação que cria vínculo com ela. Com `lock`, a linha é lida com
      # FOR SHARE: a desativação concorrente espera o fim da operação (ou a operação espera a desativação e
      # relê a filial já inativa).
      module BranchGuard
        INACTIVE = "filial inativa: escolha uma filial ativa"

        module_function

        def active!(organizations, tx, id, field:, lock: true)
          branch = organizations.find_branch(tx, Domain::Identifier.parse(id, field), lock: lock ? :share : nil)
          raise Domain::NotFound.new("filial", feminine: true) unless branch
          raise Domain::ValidationError.field(field, INACTIVE) unless branch.active

          branch
        end
      end

      # Controle otimista: a versão em branco significa "não informada" (uso interno); informada, precisa
      # ser a atual.
      module OptimisticLock
        private

        def stale!(record, lock_version, code, message)
          text = lock_version.to_s.strip
          return if text.empty? || text == record.lock_version.to_s

          raise Domain::Conflict.new(message, code: code)
        end
      end

      class GetSettings
        def initialize(uow:, organizations:, audit_log:, clock:)
          @uow = uow
          @organizations = organizations
          @audit_log = audit_log
          @clock = clock
        end

        def call(actor)
          @uow.run(actor, "organization.manage") do |tx, _current|
            now = @clock.now
            org = @organizations.find(tx, tx.tenant_id!) || raise(Domain::NotFound.new("organização", feminine: true))
            { organization: org, impact: @organizations.timezone_impact(tx, now), history: @audit_log.for_resource(tx, "organization", org.id),
              now: now }
          end
        end
      end

      # Pré-visualização: valida e calcula a revisão sem gravar, sem auditar e sem conferir a versão. A
      # troca de fuso não exige a confirmação aqui (a prévia mostra a comparação).
      class PreviewSettings
        def initialize(uow:, organizations:)
          @uow = uow
          @organizations = organizations
        end

        def call(actor, attrs)
          @uow.run(actor, "organization.manage") do |tx, _current|
            org = @organizations.find(tx, tx.tenant_id!) || raise(Domain::NotFound.new("organização", feminine: true))
            revised = org.revise(**attrs.except(:confirm_timezone_change), confirm_timezone_change: true)
            { current: org, revised: revised, timezone_changed: org.timezone_changed?(revised) }
          end
        end
      end

      # Alteração das configurações, somente por usuário (web ou API com sessão): credenciais, mesmo com o
      # escopo `organization.manage`, não alteram (a troca de fuso exige leitura e confirmação humanas, e a
      # auditoria liga a alteração a uma pessoa; ADR-028 e ADR-029). attrs: name, timezone, hold_minutes,
      # cancellation_rows ou cancellation_tiers, confirm_timezone_change. `via` identifica o canal na
      # auditoria (a API informa "api"); com `tx`, roda na transação do chamador.
      class UpdateSettings
        include OptimisticLock

        def initialize(uow:, organizations:, audit:, clock:)
          @uow = uow
          @organizations = organizations
          @audit = audit
          @clock = clock
        end

        def call(actor, attrs, lock_version: nil, via: nil, tx: nil)
          Composition.run(@uow, actor, "organization.manage", tx) do |t, current|
            raise Domain::AccessDenied, "as configurações da organização são alteradas somente por usuários" unless current.user?

            org = @organizations.lock(t, t.tenant_id!) || raise(Domain::NotFound.new("organização", feminine: true))
            stale!(org, lock_version, "stale_organization", STALE_ORGANIZATION)
            revised = org.revise(**attrs)
            next Result.new(record: org, changed: false) if revised.equal?(org)

            if @organizations.update_settings(t, revised, org.lock_version, @clock.now).zero?
              raise Domain::Conflict.new(STALE_ORGANIZATION, code: "stale_organization")
            end

            @audit.record(t, current, "organization.settings_updated", "organization", org.id, audit_details(org, revised, via))
            Result.new(record: revised, changed: true)
          end
        end

        private

        def audit_details(org, revised, via)
          details = { "changes" => org.changes(revised), "lock_version" => revised.lock_version }
          details["timezone_confirmed"] = true if org.timezone_changed?(revised)
          details["via"] = via if via
          details
        end
      end

      # Detalhe da filial com vínculos (ativos, estoque e compromissos que impedem a desativação). O
      # histórico aparece para quem gerencia a organização ou lê a auditoria.
      class GetBranch
        def initialize(uow:, organizations:, audit_log:, clock:)
          @uow = uow
          @organizations = organizations
          @audit_log = audit_log
          @clock = clock
        end

        def call(actor, branch_id)
          @uow.run(actor, "organization.read") do |tx, current|
            branch = @organizations.find_branch(tx, Domain::Identifier.parse(branch_id, "filial")) ||
                     raise(Domain::NotFound.new("filial", feminine: true))
            history = if %w[organization.manage audit.read].any? { |permission| Authorizer.allowed?(current, permission) }
                        @audit_log.for_resource(tx, "branch", branch.id)
                      end
            { branch: branch, usage: @organizations.branch_usage(tx, branch.id),
              commitments: @organizations.branch_commitments(tx, branch.id, @clock.now), history: history }
          end
        end
      end

      class UpdateBranch
        include OptimisticLock

        def initialize(uow:, organizations:, audit:, clock:)
          @uow = uow
          @organizations = organizations
          @audit = audit
          @clock = clock
        end

        def call(actor, branch_id, name:, address:, lock_version: nil)
          @uow.run(actor, "organization.manage") do |tx, current|
            branch = @organizations.lock_branch(tx, Domain::Identifier.parse(branch_id, "filial")) ||
                     raise(Domain::NotFound.new("filial", feminine: true))
            stale!(branch, lock_version, "stale_branch", STALE_BRANCH)
            revised = branch.revise(name: name, address: address)
            next Result.new(record: branch, changed: false) if revised.equal?(branch)

            raise Domain::Conflict.new(STALE_BRANCH, code: "stale_branch") if @organizations.update_branch(tx, revised, branch.lock_version, @clock.now).zero?

            @audit.record(tx, current, "branch.updated", "branch", branch.id, "code" => branch.code, "changes" => branch.changes(revised))
            Result.new(record: revised, changed: true)
          end
        end
      end

      # Desativação e reativação. A desativação trava a organização (serializa a contagem de filiais
      # ativas, inclusive sem assinatura) e recusa a última filial ativa e a filial com compromissos em
      # aberto; a reativação respeita o limite de filiais do plano (trava da assinatura).
      class SetBranchActive
        def initialize(uow:, organizations:, limits:, audit:, clock:)
          @uow = uow
          @organizations = organizations
          @limits = limits
          @audit = audit
          @clock = clock
        end

        def call(actor, branch_id, active:)
          @uow.run(actor, "organization.manage") do |tx, current|
            now = @clock.now
            branch = @organizations.lock_branch(tx, Domain::Identifier.parse(branch_id, "filial")) ||
                     raise(Domain::NotFound.new("filial", feminine: true))
            changed = active ? branch.reactivate : branch.deactivate(now)
            next Result.new(record: branch, changed: false) if changed.equal?(branch)

            active ? @limits.ensure!(tx, :branches) : ensure_deactivatable!(tx, branch, now)
            raise Domain::Conflict.new(STALE_BRANCH, code: "stale_branch") if @organizations.update_branch(tx, changed, branch.lock_version, now).zero?

            @audit.record(tx, current, active ? "branch.reactivated" : "branch.deactivated", "branch", branch.id, "code" => branch.code)
            Result.new(record: changed, changed: true)
          end
        end

        private

        def ensure_deactivatable!(tx, branch, now)
          @organizations.lock(tx, tx.tenant_id!)
          if @organizations.active_branch_count(tx) <= 1
            raise Domain::Conflict.new("A organização precisa de ao menos uma filial ativa.", code: "last_active_branch")
          end

          message = Domain::Organizations::Branch.deactivation_blockers(branch.code, @organizations.branch_commitments(tx, branch.id, now))
          raise Domain::Conflict.new(message, code: "branch_in_use") if message
        end
      end
    end
  end
end
