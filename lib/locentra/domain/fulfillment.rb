# frozen_string_literal: true

module Locentra
  module Domain
    # Retirada (separação, conferência e entrega) e devolução total ou parcial.
    #
    # Uma retirada tem uma linha por alocação ativa da reserva confirmada. Somente linhas conferidas
    # são entregues; as demais têm a alocação liberada. Cada linha entregue acumula o que voltou e o
    # que foi registrado como faltante, nunca acima do entregue.
    module Fulfillment
      PICKUP_STATUSES = { "picking" => "Em separação", "delivered" => "Entregue", "cancelled" => "Cancelada" }.freeze
      PICKUP_TRANSITIONS = { "picking" => %w[delivered cancelled], "delivered" => [], "cancelled" => [] }.freeze

      LINE_STATUSES = {
        "pending" => "Aguardando conferência", "checked" => "Conferido", "delivered" => "Entregue",
        "partial" => "Entregue parcialmente", "not_delivered" => "Não entregue", "cancelled" => "Cancelado"
      }.freeze
      OPEN_LINE_STATUSES = %w[pending checked].freeze
      DELIVERED_LINE_STATUSES = %w[delivered partial].freeze

      OUTCOMES = { "ok" => "Sem ocorrências", "damaged" => "Avariado", "missing" => "Faltante" }.freeze

      # Quem retirou: o próprio cliente pessoa física ou um contato autorizado, sempre com CPF.
      Picker = Data.define(:kind, :contact_id, :name, :document) do
        def self.customer(customer)
          raise ValidationError.field("retirante", "cliente pessoa jurídica retira somente por contato autorizado") unless customer.kind == "individual"

          new(kind: "customer", contact_id: nil, name: customer.name, document: customer.document)
        end

        def self.contact(contact)
          raise ValidationError.field("retirante", "contato não autorizado a retirar") unless contact.authorized_pickup
          raise ValidationError.field("retirante", "contato autorizado sem CPF válido") unless Customers::Document.valid_cpf?(contact.document)

          new(kind: "contact", contact_id: contact.id, name: contact.name, document: contact.document)
        end

        def formatted_document = Customers::Document.format(document)
        def kind_label = kind == "customer" ? "Cliente" : "Contato autorizado"
      end

      Pickup = Data.define(:id, :organization_id, :reservation_id, :branch_id, :status, :picker, :notes, :started_at, :delivered_at,
                           :cancelled_at, :version) do
        def self.start(id:, organization_id:, reservation:, now:)
          raise InvalidTransition.new("reserva", reservation.status, "retirada") unless reservation.status == "confirmed"

          new(id: id, organization_id: organization_id, reservation_id: reservation.id, branch_id: reservation.branch_id, status: "picking",
              picker: nil, notes: nil, started_at: now, delivered_at: nil, cancelled_at: nil, version: 1)
        end

        def status_label = PICKUP_STATUSES.fetch(status)
        def picking? = status == "picking"
        def delivered? = status == "delivered"

        def transition(target)
          raise InvalidTransition.new("retirada", status, target) unless PICKUP_TRANSITIONS.fetch(status).include?(target)

          with(status: target, version: version + 1)
        end

        def deliver(picker, now, notes: nil)
          transition("delivered").with(picker: picker, delivered_at: now, notes: Organizations::Text.optional(notes, max: 1000))
        end

        def cancel(now) = transition("cancelled").with(cancelled_at: now)
      end

      PickupLine = Data.define(:id, :pickup_id, :reservation_id, :reservation_item_id, :product_id, :asset_allocation_id,
                               :stock_allocation_id, :asset_id, :stock_pool_id, :expected_quantity, :checked_quantity,
                               :delivered_quantity, :returned_quantity, :missing_quantity, :status) do
        def self.from_allocation(id:, pickup_id:, reservation_id:, allocation:)
          asset = !allocation["asset_id"].nil?
          new(id: id, pickup_id: pickup_id, reservation_id: reservation_id, reservation_item_id: allocation["reservation_item_id"],
              product_id: allocation["product_id"], asset_allocation_id: asset ? allocation["id"] : nil,
              stock_allocation_id: asset ? nil : allocation["id"], asset_id: allocation["asset_id"], stock_pool_id: allocation["stock_pool_id"],
              expected_quantity: asset ? 1 : allocation["quantity"], checked_quantity: 0, delivered_quantity: 0, returned_quantity: 0,
              missing_quantity: 0, status: "pending")
        end

        def asset? = !asset_id.nil?
        def status_label = LINE_STATUSES.fetch(status)
        def checked? = status == "checked"
        def delivered? = DELIVERED_LINE_STATUSES.include?(status)

        # Conferência por patrimônio: o ativo informado passa a ser o ativo da linha.
        def check_asset(asset_id)
          ensure_open!
          raise ValidationError.field("patrimonio", "item de estoque é conferido por quantidade") unless asset?

          with(asset_id: asset_id, checked_quantity: 1, status: "checked")
        end

        # Conferência quantitativa: zero volta a linha para pendente.
        def check_quantity(quantity)
          ensure_open!
          raise ValidationError.field("quantidade", "ativo individual é conferido pelo patrimônio") if asset?
          raise ValidationError.field("quantidade", "entre 0 e #{expected_quantity}") unless quantity.between?(0, expected_quantity)

          with(checked_quantity: quantity, status: quantity.positive? ? "checked" : "pending")
        end

        # Entrega somente do que foi conferido; o restante fica registrado como não entregue.
        def deliver
          ensure_open!
          return with(status: "not_delivered", delivered_quantity: 0, checked_quantity: 0) unless checked?

          with(status: checked_quantity == expected_quantity ? "delivered" : "partial", delivered_quantity: checked_quantity)
        end

        def cancel
          ensure_open!
          with(status: "cancelled")
        end

        def undelivered_quantity = expected_quantity - delivered_quantity
        def pending_return = delivered? ? delivered_quantity - returned_quantity - missing_quantity : 0
        def outstanding? = pending_return.positive?

        def register_return(outcome, quantity)
          if quantity > pending_return
            raise Conflict.new("item já devolvido ou registrado como faltante (pendente: #{pending_return})", code: "already_returned")
          end

          outcome == "missing" ? with(missing_quantity: missing_quantity + quantity) : with(returned_quantity: returned_quantity + quantity)
        end

        private

        def ensure_open!
          raise InvalidTransition.new("item da retirada", status, "conferência") unless OPEN_LINE_STATUSES.include?(status)
        end
      end

      # Um item de uma devolução. Avaria exige inspeção; falta nunca passa por inspeção. Avarias e
      # faltas exigem descrição.
      ReturnEntry = Data.define(:pickup_line_id, :outcome, :quantity, :requires_inspection, :notes) do
        def self.build(pickup_line_id:, outcome:, quantity: 1, requires_inspection: false, notes: nil)
          kind = outcome.to_s
          raise ValidationError.field("resultado", "use ok, damaged ou missing") unless OUTCOMES.key?(kind)

          qty = Integer(quantity.to_s, 10)
          raise ValidationError.field("quantidade", "deve ser positiva") unless qty.positive?

          text = Organizations::Text.optional(notes, max: 1000)
          raise ValidationError.field("observacoes", "descreva a avaria ou a falta (ao menos 3 caracteres)") if kind != "ok" && text.to_s.length < 3

          inspection = case kind
                       when "damaged" then true
                       when "missing" then false
                       else requires_inspection ? true : false
                       end
          new(pickup_line_id: Identifier.parse(pickup_line_id, "item"), outcome: kind, quantity: qty, requires_inspection: inspection, notes: text)
        rescue ArgumentError
          raise ValidationError.field("quantidade", "número inteiro")
        end

        def missing? = outcome == "missing"
        def damaged? = outcome == "damaged"
        def outcome_label = OUTCOMES.fetch(outcome)
      end

      # Aplica as entradas de uma devolução às linhas entregues (acumulado nunca acima do entregue).
      module ReturnPlan
        module_function

        # lines: { id => PickupLine } com as linhas entregues da retirada.
        def apply(lines, entries)
          raise ValidationError.field("itens", "informe ao menos um item devolvido ou faltante") if entries.empty?

          entries.each_with_object(lines.dup) do |entry, acc|
            line = acc.fetch(entry.pickup_line_id) { raise NotFound, "item da retirada" }
            raise ValidationError.field("quantidade", "ativo individual é devolvido por unidade") if line.asset? && entry.quantity != 1

            acc[line.id] = line.register_return(entry.outcome, entry.quantity)
          end
        end

        def complete?(lines) = lines.values.none?(&:outstanding?)
      end

      # Multa por atraso por item da reserva, calculada com a tabela do snapshot do item.
      #
      # - Itens simples: cobrados pela quantidade devolvida após o fim previsto; faltas não geram
      #   multa (são cobradas pelo custo de reposição, mediante aprovação).
      # - Kits: cobrados pela quantidade do item quando a última pendência do kit é resolvida.
      module LateFeePolicy
        module_function

        # items: { item_id => { "pricing" => ..., "quantity" => n, "tracking" => "kit" | ... } }
        def charges(items:, entries:, before:, after:, scheduled_end:, returned_at:, zone:)
          return [] unless returned_at > scheduled_end

          entries.group_by { |entry| before.fetch(entry.pickup_line_id).reservation_item_id }.filter_map do |item_id, list|
            item = items.fetch(item_id)
            table = item.fetch("pricing", {}).fetch("table", {})
            next if table.empty?

            quantity = chargeable_quantity(item, item_id, list, before, after)
            next unless quantity.positive?

            amount = Pricing::LateFee.calculate(table: Pricing::PriceTable.from_h(table), scheduled_end: scheduled_end, returned_at: returned_at,
                                                quantity: quantity, zone: zone)
            { item_id: item_id, quantity: quantity, amount: amount } if amount.positive?
          end
        end

        def chargeable_quantity(item, item_id, entries, before, after)
          return entries.reject(&:missing?).sum(&:quantity) unless item["tracking"] == "kit"

          was_open = before.values.any? { |l| l.reservation_item_id == item_id && l.outstanding? }
          now_closed = after.values.none? { |l| l.reservation_item_id == item_id && l.outstanding? }
          was_open && now_closed ? item.fetch("quantity") : 0
        end
      end
    end
  end
end
