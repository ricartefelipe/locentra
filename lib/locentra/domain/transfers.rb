# frozen_string_literal: true

module Locentra
  module Domain
    # Transferência entre filiais: solicitada -> em trânsito (saída) -> recebida; cancelável antes da saída.
    #
    # O ativo em trânsito não aparece disponível em nenhuma filial: fica com situação `in_transit` e só
    # muda de filial no recebimento. No estoque quantitativo, a quantidade sai do estoque de origem na
    # saída e entra no de destino no recebimento.
    module Transfers
      STATUSES = { "requested" => "Solicitada", "in_transit" => "Em trânsito", "received" => "Recebida", "cancelled" => "Cancelada" }.freeze
      TRANSITIONS = { "requested" => %w[in_transit cancelled], "in_transit" => %w[received], "received" => [], "cancelled" => [] }.freeze
      MAX_QUANTITY = 100_000

      Transfer = Data.define(:id, :organization_id, :code, :product_id, :asset_id, :quantity, :from_branch_id, :to_branch_id,
                             :from_pool_id, :to_pool_id, :status, :notes, :requested_at, :dispatched_at, :received_at,
                             :cancelled_at, :cancellation_reason, :version) do
        def self.build(id:, organization_id:, code:, product_id:, from_branch_id:, to_branch_id:, requested_at:, asset_id: nil,
                       from_pool_id: nil, quantity: 1, notes: nil)
          raise ValidationError.field("destino", "a filial de destino deve ser diferente da origem") if from_branch_id == to_branch_id
          raise ArgumentError, "informe ativo ou estoque de origem" if asset_id.nil? == from_pool_id.nil?

          qty = asset_id ? 1 : quantity
          raise ValidationError.field("quantidade", "entre 1 e #{MAX_QUANTITY}") unless qty.is_a?(Integer) && qty.between?(1, MAX_QUANTITY)

          new(id: id, organization_id: organization_id, code: code, product_id: product_id, asset_id: asset_id, quantity: qty,
              from_branch_id: from_branch_id, to_branch_id: to_branch_id, from_pool_id: from_pool_id, to_pool_id: nil, status: "requested",
              notes: Organizations::Text.optional(notes, max: 500), requested_at: requested_at, dispatched_at: nil, received_at: nil,
              cancelled_at: nil, cancellation_reason: nil, version: 1)
        end

        def asset? = !asset_id.nil?
        def status_label = STATUSES.fetch(status)
        def active? = %w[requested in_transit].include?(status)

        def dispatch(now) = transition("in_transit").with(dispatched_at: now)
        def receive(now, to_pool_id: nil) = transition("received").with(received_at: now, to_pool_id: to_pool_id)

        def cancel(reason, now)
          transition("cancelled").with(cancellation_reason: Organizations::Text.required(reason, "motivo", max: 500), cancelled_at: now)
        end

        private

        def transition(target)
          raise InvalidTransition.new("transferência", status, target) unless TRANSITIONS.fetch(status).include?(target)

          with(status: target, version: version + 1)
        end
      end
    end
  end
end
