# frozen_string_literal: true

module Locentra
  module Domain
    # Inspeção, ordens de manutenção e registros de avaria ou falta.
    #
    # Itens em inspeção ou manutenção permanecem indisponíveis: ativos pela situação operacional e
    # estoque por uma alocação de bloqueio aberta, encerrada somente na liberação.
    module Maintenance
      INSPECTION_STATUSES = { "pending" => "Pendente", "approved" => "Aprovada", "rejected" => "Reprovada" }.freeze
      INSPECTION_TRANSITIONS = { "pending" => %w[approved rejected], "approved" => [], "rejected" => [] }.freeze

      Inspection = Data.define(:id, :organization_id, :product_id, :branch_id, :asset_id, :stock_pool_id, :quantity, :block_allocation_id,
                               :reservation_id, :return_line_id, :source_maintenance_order_id, :status, :reason, :decision_notes,
                               :maintenance_order_id, :created_at, :decided_at) do
        def self.build(id:, organization_id:, product_id:, branch_id:, reason:, created_at:, asset_id: nil, stock_pool_id: nil, quantity: 1,
                       block_allocation_id: nil, reservation_id: nil, return_line_id: nil, source_maintenance_order_id: nil)
          raise ArgumentError, "informe ativo ou estoque" if asset_id.nil? == stock_pool_id.nil?
          raise ArgumentError, "estoque em inspeção exige bloqueio" if stock_pool_id && block_allocation_id.nil?

          new(id: id, organization_id: organization_id, product_id: product_id, branch_id: branch_id, asset_id: asset_id,
              stock_pool_id: stock_pool_id, quantity: asset_id ? 1 : quantity, block_allocation_id: block_allocation_id,
              reservation_id: reservation_id, return_line_id: return_line_id, source_maintenance_order_id: source_maintenance_order_id,
              status: "pending", reason: Organizations::Text.required(reason, "motivo", max: 500), decision_notes: nil,
              maintenance_order_id: nil, created_at: created_at, decided_at: nil)
        end

        def asset? = !asset_id.nil?
        def pending? = status == "pending"
        def status_label = INSPECTION_STATUSES.fetch(status)

        def approve(notes, now) = decide("approved", Organizations::Text.optional(notes, max: 1000), now)

        def reject(notes, maintenance_order_id, now)
          decide("rejected", Organizations::Text.required(notes, "motivo", max: 1000), now).with(maintenance_order_id: maintenance_order_id)
        end

        private

        def decide(target, notes, now)
          raise InvalidTransition.new("inspeção", status, target) unless INSPECTION_TRANSITIONS.fetch(status).include?(target)

          with(status: target, decision_notes: notes, decided_at: now)
        end
      end

      ORDER_STATUSES = { "open" => "Aberta", "in_progress" => "Em execução", "completed" => "Concluída", "cancelled" => "Cancelada" }.freeze
      ORDER_TRANSITIONS = {
        "open" => %w[in_progress cancelled], "in_progress" => %w[completed cancelled], "completed" => [], "cancelled" => []
      }.freeze
      ACTIVE_ORDER_STATUSES = %w[open in_progress].freeze

      Order = Data.define(:id, :organization_id, :code, :product_id, :branch_id, :asset_id, :stock_pool_id, :quantity, :block_allocation_id,
                          :inspection_id, :previous_status, :status, :description, :cost, :requires_inspection, :resolution_notes,
                          :opened_at, :started_at, :completed_at, :cancelled_at, :cancellation_reason, :version) do
        def self.build(id:, organization_id:, code:, product_id:, branch_id:, description:, opened_at:, asset_id: nil, stock_pool_id: nil,
                       quantity: 1, block_allocation_id: nil, inspection_id: nil, previous_status: nil)
          raise ArgumentError, "informe ativo ou estoque" if asset_id.nil? == stock_pool_id.nil?

          qty = asset_id ? 1 : quantity
          raise ValidationError.field("quantidade", "deve ser positiva") unless qty.is_a?(Integer) && qty.positive?

          new(id: id, organization_id: organization_id, code: code, product_id: product_id, branch_id: branch_id, asset_id: asset_id,
              stock_pool_id: stock_pool_id, quantity: qty, block_allocation_id: block_allocation_id, inspection_id: inspection_id,
              previous_status: previous_status, status: "open",
              description: Organizations::Text.required(description, "descricao", min: 3, max: 2000), cost: nil, requires_inspection: nil,
              resolution_notes: nil, opened_at: opened_at, started_at: nil, completed_at: nil, cancelled_at: nil, cancellation_reason: nil,
              version: 1)
        end

        def asset? = !asset_id.nil?
        def active? = ACTIVE_ORDER_STATUSES.include?(status)
        def status_label = ORDER_STATUSES.fetch(status)

        def start(now) = transition("in_progress").with(started_at: now)

        def complete(cost:, requires_inspection:, now:, notes: nil)
          raise ValidationError.field("custo", "não pode ser negativo") if cost.negative?

          transition("completed").with(cost: cost, requires_inspection: requires_inspection ? true : false, completed_at: now,
                                       resolution_notes: Organizations::Text.optional(notes, max: 2000))
        end

        def cancel(reason, now)
          transition("cancelled").with(cancellation_reason: Organizations::Text.required(reason, "motivo", max: 500), cancelled_at: now)
        end

        # Situação do ativo ao cancelar: volta para inspeção quando veio de uma inspeção reprovada.
        def status_after_cancel = previous_status == "in_inspection" ? "in_inspection" : "available"

        private

        def transition(target)
          raise InvalidTransition.new("ordem de manutenção", status, target) unless ORDER_TRANSITIONS.fetch(status).include?(target)

          with(status: target, version: version + 1)
        end
      end

      DAMAGE_KINDS = { "damage" => "Avaria", "missing" => "Falta" }.freeze
      SEVERITIES = { "minor" => "Leve", "moderate" => "Moderada", "severe" => "Grave", "total_loss" => "Perda total" }.freeze
      DAMAGE_STATUSES = { "open" => "Aguardando aprovação", "approved" => "Cobrança aprovada", "dismissed" => "Descartada" }.freeze
      DAMAGE_TRANSITIONS = { "open" => %w[approved dismissed], "approved" => [], "dismissed" => [] }.freeze

      DamageReport = Data.define(:id, :organization_id, :code, :reservation_id, :reservation_item_id, :return_line_id, :product_id,
                                 :asset_id, :stock_pool_id, :quantity, :kind, :severity, :description, :estimated_cost, :status,
                                 :charged, :adjustment_id, :decision_notes, :version) do
        def self.build(id:, organization_id:, code:, reservation_id:, reservation_item_id:, return_line_id:, product_id:, quantity:, kind:,
                       severity:, description:, estimated_cost:, asset_id: nil, stock_pool_id: nil)
          raise ValidationError.field("tipo", "use damage ou missing") unless DAMAGE_KINDS.key?(kind)
          raise ArgumentError, "informe ativo ou estoque" if asset_id.nil? == stock_pool_id.nil?

          new(id: id, organization_id: organization_id, code: code, reservation_id: reservation_id, reservation_item_id: reservation_item_id,
              return_line_id: return_line_id, product_id: product_id, asset_id: asset_id, stock_pool_id: stock_pool_id, quantity: quantity,
              kind: kind, status: "open", charged: nil, adjustment_id: nil, decision_notes: nil, version: 1,
              **attributes(description: description, severity: severity, estimated_cost: estimated_cost))
        end

        def self.attributes(description:, severity:, estimated_cost:)
          raise ValidationError.field("severidade", "severidade inválida") unless SEVERITIES.key?(severity.to_s)
          raise ValidationError.field("custo_estimado", "não pode ser negativo") if estimated_cost.negative?

          { description: Organizations::Text.required(description, "descricao", min: 3, max: 2000), severity: severity.to_s,
            estimated_cost: estimated_cost }
        end

        def open? = status == "open"
        def kind_label = DAMAGE_KINDS.fetch(kind)
        def severity_label = SEVERITIES.fetch(severity)
        def status_label = DAMAGE_STATUSES.fetch(status)

        def revise(description:, severity:, estimated_cost:)
          raise InvalidTransition.new("registro de avaria", status, "revisão") unless open?

          with(**self.class.attributes(description: description, severity: severity, estimated_cost: estimated_cost), version: version + 1)
        end

        # A cobrança exige ao menos uma evidência anexada e valor positivo.
        def approve(amount:, evidence_count:, adjustment_id:, notes: nil)
          unless evidence_count.positive?
            raise ValidationError.field("evidencias", "anexe ao menos uma evidência antes de aprovar a cobrança")
          end
          raise ValidationError.field("valor", "a cobrança deve ser positiva") unless amount.positive?

          transition("approved").with(charged: amount, adjustment_id: adjustment_id, decision_notes: Organizations::Text.optional(notes, max: 1000))
        end

        def dismiss(reason)
          transition("dismissed").with(decision_notes: Organizations::Text.required(reason, "motivo", max: 1000))
        end

        private

        def transition(target)
          raise InvalidTransition.new("registro de avaria", status, target) unless DAMAGE_TRANSITIONS.fetch(status).include?(target)

          with(status: target, version: version + 1)
        end
      end
    end
  end
end
