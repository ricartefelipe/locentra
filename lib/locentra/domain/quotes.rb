# frozen_string_literal: true

module Locentra
  module Domain
    # Orçamentos versionados. Cada alteração relevante cria uma nova versão imutável; a aprovação
    # identifica a versão aceita e só vale para a versão atual de um orçamento enviado e vigente.
    module Quotes
      STATUSES = {
        "draft" => "Rascunho",
        "sent" => "Enviado",
        "approved" => "Aprovado",
        "rejected" => "Rejeitado",
        "expired" => "Expirado",
        "converted" => "Convertido em reserva"
      }.freeze

      # Máquina de estados. `sent -> draft` ocorre quando uma nova versão é criada após o envio
      # (exige reenvio); `rejected`/`expired -> draft` reabrem o orçamento com nova versão.
      TRANSITIONS = {
        "draft" => %w[sent],
        "sent" => %w[approved rejected expired draft],
        "approved" => %w[converted],
        "rejected" => %w[draft],
        "expired" => %w[draft],
        "converted" => []
      }.freeze

      REVISABLE = %w[draft sent rejected expired].freeze

      HOLD_POLICIES = {
        "none" => "Sem bloqueio: o orçamento enviado não garante disponibilidade",
        "hold_on_send" => "Bloqueio temporário ao enviar: reserva a disponibilidade por tempo limitado"
      }.freeze

      APPROVER_TYPES = { "staff" => "Equipe em nome do cliente", "customer" => "Próprio cliente" }.freeze

      MAX_VALIDITY_DAYS = 90
      MAX_TERMS_LENGTH = 5000

      module Rules
        module_function

        def hold_policy!(value)
          policy = value.to_s.empty? ? "none" : value.to_s
          raise ValidationError.field("politica_bloqueio", "use none ou hold_on_send") unless HOLD_POLICIES.key?(policy)

          policy
        end

        # Validade do bloqueio temporário criado no envio (limitada a 1440 minutos).
        def hold_minutes!(policy, value)
          return nil if policy == "none"

          Reservations::Rules.hold_minutes!(value)
        end

        # A validade termina no futuro, em até 90 dias e não depois do início da locação.
        def valid_until!(valid_until, period:, now:)
          raise ValidationError.field("validade", "obrigatória") unless valid_until.is_a?(Time)

          instant = Time.at(valid_until.to_i).utc
          raise ValidationError.field("validade", "deve ser posterior ao momento atual") unless instant > now
          raise ValidationError.field("validade", "no máximo #{MAX_VALIDITY_DAYS} dias") if instant > now + (MAX_VALIDITY_DAYS * 86_400)
          raise ValidationError.field("validade", "deve terminar até o início da locação") if instant > period.starts_at

          instant
        end

        def terms(value) = Organizations::Text.optional(value, max: MAX_TERMS_LENGTH)
      end

      # Quem aprovou: a equipe em nome do cliente (registrando o nome de quem aceitou) ou o próprio
      # cliente pelo portal. IP e instante são gravados junto.
      Approver = Data.define(:type, :user_id, :name, :ip) do
        def self.build(type:, user_id:, name:, ip:)
          raise ValidationError.field("aprovador", "tipo inválido") unless APPROVER_TYPES.key?(type)

          new(type: type, user_id: user_id, name: Organizations::Text.required(name, "aprovado_por", min: 2, max: 160),
              ip: Organizations::Text.optional(ip, max: 64))
        end
      end

      # Versão imutável: itens precificados, período, validade, condições e totais.
      Version = Data.define(:id, :quote_id, :number, :branch_id, :period, :valid_until, :items, :pricing, :terms,
                            :manual_discount_bps, :deposit, :total, :created_at) do
        def expired?(now) = now >= valid_until

        def lines
          items.map { |item| Reservations::Line.new(product_id: item.fetch("product_id"), quantity: item.fetch("quantity")) }
        end

        # Conteúdo comparável: duas versões iguais não justificam nova versão.
        def fingerprint
          [branch_id, period, valid_until.to_i, terms, manual_discount_bps, total.cents, deposit.cents,
           items.map { |i| [i.fetch("product_id"), i.fetch("quantity"), i.fetch("total_cents")] }.sort]
        end
      end

      Quote = Data.define(:id, :organization_id, :code, :customer_id, :branch_id, :status, :current_version, :approved_version,
                          :hold_policy, :hold_minutes, :hold_reservation_id, :reservation_id, :sent_at, :approved_at,
                          :approved_by_type, :approved_by_user_id, :approved_by_name, :approved_ip, :rejected_at, :rejection_reason,
                          :expired_at, :converted_at, :lock_version) do
        # Novo orçamento em rascunho com código provisório (o definitivo é atribuído no fim da transação).
        def self.draft(id:, organization_id:, customer_id:, branch_id:, hold_policy:, hold_minutes:)
          new(id: id, organization_id: organization_id, code: "PEND-#{id}", customer_id: customer_id, branch_id: branch_id,
              status: "draft", current_version: 1, approved_version: nil, hold_policy: hold_policy, hold_minutes: hold_minutes,
              hold_reservation_id: nil, reservation_id: nil, sent_at: nil, approved_at: nil, approved_by_type: nil,
              approved_by_user_id: nil, approved_by_name: nil, approved_ip: nil, rejected_at: nil, rejection_reason: nil,
              expired_at: nil, converted_at: nil, lock_version: 1)
        end

        def status_label = STATUSES.fetch(status)
        def hold_on_send? = hold_policy == "hold_on_send"
        def revisable? = REVISABLE.include?(status)
        def approver_label = approved_by_type && APPROVER_TYPES.fetch(approved_by_type)

        def transition(target)
          raise InvalidTransition.new("orçamento", status, target) unless TRANSITIONS.fetch(status).include?(target)

          with(status: target, lock_version: lock_version + 1)
        end

        # Envio da versão atual. A validade precisa estar vigente e o período não pode ter começado.
        def send_version(version, now)
          raise InvalidTransition.new("orçamento", status, "sent") unless status == "draft"
          raise InvariantViolation, "versão diferente da atual" unless version.number == current_version
          raise ValidationError.field("validade", "expirada; crie uma nova versão com nova validade") if version.expired?(now)

          Reservations::Rules.validate_start!(version.period, now)
          transition("sent").with(sent_at: now, hold_reservation_id: nil)
        end

        def with_hold(reservation_id) = with(hold_reservation_id: reservation_id)

        # Aprovação da versão informada. Rejeita orçamento não enviado, versão desatualizada e
        # validade vencida.
        def approve(number, version:, approver:, now:)
          raise Conflict.new("Orçamento expirado: crie uma nova versão com nova validade", code: "quote_expired") if status == "expired"
          raise InvalidTransition.new("orçamento", status, "approved") unless status == "sent"

          unless number == current_version && version.number == current_version
            raise Conflict.new("A versão #{number} não é a versão atual do orçamento (versão atual: #{current_version})",
                               code: "stale_quote_version")
          end
          raise Conflict.new("Orçamento expirado: crie uma nova versão com nova validade", code: "quote_expired") if version.expired?(now)

          transition("approved").with(approved_version: number, approved_at: now, approved_by_type: approver.type,
                                      approved_by_user_id: approver.user_id, approved_by_name: approver.name, approved_ip: approver.ip)
        end

        def reject(reason, now)
          transition("rejected").with(rejected_at: now, rejection_reason: Organizations::Text.required(reason, "motivo", max: 500))
        end

        def expire(now) = transition("expired").with(expired_at: now)

        # Nova versão: volta a rascunho e exige novo envio. O bloqueio anterior deixa de valer.
        def revise(branch_id:, hold_policy:, hold_minutes:)
          raise InvalidTransition.new("orçamento", status, "nova versão") unless revisable?

          base = status == "draft" ? with(lock_version: lock_version + 1) : transition("draft")
          base.with(current_version: current_version + 1, branch_id: branch_id, hold_policy: hold_policy, hold_minutes: hold_minutes,
                    hold_reservation_id: nil, sent_at: nil, rejected_at: nil, rejection_reason: nil, expired_at: nil)
        end

        def convert(reservation_id, now) = transition("converted").with(reservation_id: reservation_id, converted_at: now)
      end
    end
  end
end
