# frozen_string_literal: true

module Locentra
  module Application
    # Inspeção de itens devolvidos ou reparados e registros de avaria/falta com cobrança aprovada.
    module Inspections
      M = Domain::Maintenance
      Keys = Domain::Alerts::Keys

      # Aprovar libera o item: ativo volta a disponível; o bloqueio de estoque é encerrado no instante
      # da aprovação.
      class ApproveInspection
        def initialize(uow:, inspections:, catalog:, allocations:, ledger:, audit:, clock:)
          @uow = uow
          @inspections = inspections
          @catalog = catalog
          @allocations = allocations
          @ledger = ledger
          @audit = audit
          @clock = clock
        end

        def call(actor, inspection_id, notes: nil)
          @uow.run(actor, "inspections.write") do |tx, current|
            inspection = @inspections.lock(tx, Domain::Identifier.parse(inspection_id)) || raise(Domain::NotFound, "inspeção")
            now = @clock.now
            approved = inspection.approve(notes, now)
            if inspection.asset?
              asset = @catalog.lock_asset(tx, inspection.asset_id)
              @ledger.move(tx, current, asset, "available", kind: "inspection_approved", now: now, reference_type: "inspection",
                                                            reference_id: inspection.id, notes: approved.decision_notes)
            else
              @allocations.end_stock_block(tx, inspection.block_allocation_id, now)
            end
            @inspections.update(tx, approved, current.audit_actor_id)
            @audit.record(tx, current, "inspection.approved", "inspection", inspection.id,
                          "asset_id" => inspection.asset_id, "stock_pool_id" => inspection.stock_pool_id, "quantity" => inspection.quantity)
            approved
          end
        end
      end

      # Reprovar abre ordem de manutenção e mantém o item indisponível. Reservas futuras do ativo são
      # realocadas; as que ficarem sem unidade recebem alerta para decisão.
      class RejectInspection
        def initialize(uow:, inspections:, catalog:, desk:, ledger:, relocation:, alert_book:, audit:, clock:)
          @uow = uow
          @inspections = inspections
          @catalog = catalog
          @desk = desk
          @ledger = ledger
          @relocation = relocation
          @alert_book = alert_book
          @audit = audit
          @clock = clock
        end

        def call(actor, inspection_id, notes:, description: nil)
          @uow.run(actor, "inspections.write") do |tx, current|
            inspection = @inspections.lock(tx, Domain::Identifier.parse(inspection_id)) || raise(Domain::NotFound, "inspeção")
            raise Domain::InvalidTransition.new("inspeção", inspection.status, "rejected") unless inspection.pending?

            now = @clock.now
            reason = Domain::Organizations::Text.required(notes, "motivo", max: 1000)
            order = @desk.open_order(tx, current, product_id: inspection.product_id, branch_id: inspection.branch_id, now: now,
                                                  description: description.to_s.strip.empty? ? reason : description, asset_id: inspection.asset_id,
                                                  pool_id: inspection.stock_pool_id, quantity: inspection.quantity,
                                                  block_allocation_id: inspection.block_allocation_id, inspection_id: inspection.id,
                                                  previous_status: inspection.asset? ? "in_inspection" : nil)
            divert_asset(tx, current, inspection, order, now) if inspection.asset?
            rejected = inspection.reject(reason, order.id, now)
            @inspections.update(tx, rejected, current.audit_actor_id)
            @audit.record(tx, current, "inspection.rejected", "inspection", inspection.id, "maintenance_order_id" => order.id, "code" => order.code)
            { inspection: rejected, order: order }
          end
        end

        private

        def divert_asset(tx, current, inspection, order, now)
          asset = @catalog.lock_asset(tx, inspection.asset_id)
          moved = @ledger.move(tx, current, asset, "in_maintenance", kind: "maintenance_opened", now: now, reference_type: "maintenance_order",
                                                                     reference_id: order.id, notes: order.description)
          unresolved = @relocation.relocate(tx, moved, now).map { |allocation| allocation["reservation_id"] }.uniq
          @alert_book.unavailable(tx, unresolved, resource_id: asset.id, source_id: order.id, asset_id: asset.id,
                                                  details: { "tag" => asset.tag, "reason" => "em manutenção (#{order.code})" })
        end
      end

      class ListInspections
        def initialize(uow:, inspections:)
          @uow = uow
          @inspections = inspections
        end

        def call(actor, status: "pending", limit: 100)
          raise Domain::ValidationError.field("situacao", "inválida") unless %w[pending decided].include?(status)

          @uow.run(actor, "reservations.read") { |tx, _| @inspections.list(tx, status: status, limit: limit) }
        end
      end

      # Registro manual de avaria encontrada após a devolução (por exemplo, durante a inspeção).
      # Faltas são registradas na própria devolução.
      class CreateDamageReport
        def initialize(uow:, fulfillment:, damage_reports:, organizations:, audit:, clock:, ids:)
          @uow = uow
          @fulfillment = fulfillment
          @damage_reports = damage_reports
          @organizations = organizations
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, return_line_id:, description:, severity:, estimated_cost:)
          @uow.run(actor, "inspections.write") do |tx, current|
            line = @fulfillment.find_return_line(tx, Domain::Identifier.parse(return_line_id, "item")) || raise(Domain::NotFound, "item devolvido")
            raise Domain::ValidationError.field("item", "faltas são registradas na devolução") if line["outcome"] == "missing"

            report = M::DamageReport.build(
              id: @ids.uuid, organization_id: tx.tenant_id!, code: @organizations.next_code(tx, "damage_report", "AV"),
              reservation_id: line["reservation_id"], reservation_item_id: line["reservation_item_id"], return_line_id: line["id"],
              product_id: line["product_id"], asset_id: line["asset_id"], stock_pool_id: line["stock_pool_id"], quantity: line["quantity"],
              kind: "damage", severity: severity, description: description, estimated_cost: estimated_cost
            )
            @damage_reports.insert(tx, report, current.audit_actor_id, @clock.now)
            @audit.record(tx, current, "damage_report.created", "damage_report", report.id, "code" => report.code, "return_line_id" => line["id"])
            report
          end
        end
      end

      class ReviseDamageReport
        def initialize(uow:, damage_reports:, audit:, clock:)
          @uow = uow
          @damage_reports = damage_reports
          @audit = audit
          @clock = clock
        end

        def call(actor, report_id, description:, severity:, estimated_cost:)
          @uow.run(actor, "inspections.write") do |tx, current|
            report = @damage_reports.lock(tx, Domain::Identifier.parse(report_id)) || raise(Domain::NotFound, "registro de avaria")
            revised = report.revise(description: description, severity: severity, estimated_cost: estimated_cost)
            @damage_reports.update(tx, revised, current.audit_actor_id, @clock.now)
            @audit.record(tx, current, "damage_report.revised", "damage_report", report.id,
                          "severity" => revised.severity, "estimated_cost_cents" => revised.estimated_cost.cents)
            revised
          end
        end
      end

      # Evidências de avaria só mudam enquanto o registro está aberto. Anexar ou remover bloqueia o
      # registro (o mesmo lock da aprovação): uma remoção concorrente termina antes da contagem de
      # evidências ou encontra o registro já decidido; depois da decisão as evidências são preservadas.
      class EvidenceGuard
        def initialize(damage_reports:)
          @damage_reports = damage_reports
        end

        def editable!(tx, report_id)
          report = @damage_reports.lock(tx, report_id) || raise(Domain::NotFound, "registro de avaria")
          return report if report.open?

          raise Domain::Conflict.new("#{report.code} já foi decidido: as evidências do registro são preservadas", code: "damage_report_decided")
        end
      end

      # A cobrança só é gravada (ajuste da reserva) após aprovação por quem tem damage_charges.approve e
      # com ao menos uma evidência anexada. Faltas usam por padrão o custo de reposição do produto.
      #
      # `version` é a versão do registro exibida ao aprovador: uma revisão posterior (por quem não
      # aprova cobranças) invalida a aprovação, para que o valor cobrado seja sempre o que foi visto.
      class ApproveDamageCharge
        def initialize(uow:, damage_reports:, reservations:, audit:, clock:, ids:)
          @uow = uow
          @damage_reports = damage_reports
          @reservations = reservations
          @audit = audit
          @clock = clock
          @ids = ids
        end

        def call(actor, report_id, version:, amount: nil, notes: nil)
          expected = version!(version)
          @uow.run(actor, "damage_charges.approve") do |tx, current|
            report = @damage_reports.lock(tx, Domain::Identifier.parse(report_id)) || raise(Domain::NotFound, "registro de avaria")
            ensure_current!(report, expected)
            now = @clock.now
            charge = amount || report.estimated_cost
            adjustment_id = @ids.uuid
            approved = report.approve(amount: charge, evidence_count: @damage_reports.lock_evidence_count(tx, report.id), adjustment_id: adjustment_id,
                                      notes: notes)
            @reservations.insert_adjustment(tx, "id" => adjustment_id, "reservation_id" => report.reservation_id,
                                                "reservation_item_id" => report.reservation_item_id, "kind" => report.kind,
                                                "amount_cents" => charge.cents, "created_by" => current.audit_actor_id, "created_at" => now,
                                                "details" => { "damage_report_id" => report.id, "code" => report.code, "quantity" => report.quantity,
                                                               "description" => report.description })
            @damage_reports.update(tx, approved, current.audit_actor_id, now)
            @audit.record(tx, current, "damage_charge.approved", "damage_report", report.id, "code" => report.code, "amount_cents" => charge.cents,
                                                                                             "kind" => report.kind)
            approved
          end
        end

        private

        def version!(value)
          Integer(value.to_s.strip, 10)
        rescue ArgumentError
          raise Domain::ValidationError.field("versao", "recarregue o registro antes de aprovar")
        end

        # Registro decidido segue para a transição do domínio (InvalidTransition); aberto e revisado
        # depois de exibido é recusado.
        def ensure_current!(report, expected)
          return if !report.open? || report.version == expected

          raise Domain::Conflict.new("#{report.code} foi revisado depois de exibido (custo estimado atual: #{report.estimated_cost.format_brl}); " \
                                     "confira o registro e aprove novamente", code: "stale_damage_report")
        end
      end

      class DismissDamageReport
        def initialize(uow:, damage_reports:, audit:, clock:)
          @uow = uow
          @damage_reports = damage_reports
          @audit = audit
          @clock = clock
        end

        def call(actor, report_id, reason:)
          @uow.run(actor, "damage_charges.approve") do |tx, current|
            report = @damage_reports.lock(tx, Domain::Identifier.parse(report_id)) || raise(Domain::NotFound, "registro de avaria")
            dismissed = report.dismiss(reason)
            @damage_reports.update(tx, dismissed, current.audit_actor_id, @clock.now)
            @audit.record(tx, current, "damage_report.dismissed", "damage_report", report.id, "reason" => dismissed.decision_notes)
            dismissed
          end
        end
      end

      class GetDamageReport
        def initialize(uow:, damage_reports:, attachments:)
          @uow = uow
          @damage_reports = damage_reports
          @attachments = attachments
        end

        def call(actor, report_id)
          @uow.run(actor, "reservations.read") do |tx, _|
            report = @damage_reports.find(tx, Domain::Identifier.parse(report_id)) || raise(Domain::NotFound, "registro de avaria")
            { report: report, labels: @damage_reports.labels(tx, report.id), attachments: @attachments.for_owner(tx, "damage_report", report.id) }
          end
        end
      end

      class ListDamageReports
        FILTERS = %w[open decided all].freeze

        def initialize(uow:, damage_reports:)
          @uow = uow
          @damage_reports = damage_reports
        end

        def call(actor, filter: "open")
          raise Domain::ValidationError.field("situacao", "inválida") unless FILTERS.include?(filter)

          @uow.run(actor, "reservations.read") { |tx, _| @damage_reports.list(tx, filter: filter) }
        end
      end
    end
  end
end
