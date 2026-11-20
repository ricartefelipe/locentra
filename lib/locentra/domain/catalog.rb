# frozen_string_literal: true

module Locentra
  module Domain
    module Catalog
      TRACKING = {
        "serialized" => "Ativo individual",
        "bulk" => "Estoque quantitativo",
        "kit" => "Kit"
      }.freeze

      Product = Data.define(:id, :organization_id, :sku, :name, :description, :category, :tracking,
                            :buffer_before_minutes, :buffer_after_minutes, :deposit, :replacement_cost, :pricing, :active) do
        def self.build(id:, organization_id:, sku:, name:, tracking:, description: nil, category: nil,
                       buffer_before_minutes: 0, buffer_after_minutes: 0, deposit: Money.zero, replacement_cost: Money.zero, pricing: {})
          clean_sku = sku.to_s.strip.upcase
          raise ValidationError.field("sku", "use letras, números e hífen (até 40)") unless clean_sku.match?(/\A[A-Z0-9][A-Z0-9-]{0,39}\z/)
          raise ValidationError.field("rastreamento", "modalidade inválida") unless TRACKING.key?(tracking)

          before = minutes!(buffer_before_minutes, "preparacao_antes")
          after = minutes!(buffer_after_minutes, "preparacao_depois")
          raise ValidationError.field("caucao", "não pode ser negativa") if deposit.negative?
          raise ValidationError.field("custo_reposicao", "não pode ser negativo") if replacement_cost.negative?

          new(id: id, organization_id: organization_id, sku: clean_sku,
              name: Organizations::Text.required(name, "nome", min: 2, max: 160),
              description: Organizations::Text.optional(description), category: Organizations::Text.optional(category, max: 80),
              tracking: tracking, buffer_before_minutes: before, buffer_after_minutes: after,
              deposit: deposit, replacement_cost: replacement_cost, pricing: pricing, active: true)
        end

        def self.minutes!(value, field)
          text = value.to_s.strip
          minutes = text.empty? ? 0 : Integer(text, 10)
          raise ValidationError.field(field, "entre 0 e 10080 minutos") unless minutes.between?(0, 10_080)

          minutes
        rescue ArgumentError
          raise ValidationError.field(field, "número inteiro de minutos")
        end

        def serialized? = tracking == "serialized"
        def bulk? = tracking == "bulk"
        def kit? = tracking == "kit"

        def tracking_label = TRACKING.fetch(tracking)

        # Período bloqueado para uma locação: inclui preparação antes e depois.
        def blocked_period(rental_period)
          rental_period.expand(before: buffer_before_minutes * 60, after: buffer_after_minutes * 60)
        end
      end

      CONDITIONS = {
        "new" => "Novo", "good" => "Bom", "fair" => "Regular", "poor" => "Ruim", "damaged" => "Avariado"
      }.freeze

      ASSET_STATUSES = {
        "available" => "Disponível",
        "checked_out" => "Com cliente",
        "in_inspection" => "Em inspeção",
        "in_maintenance" => "Em manutenção",
        "in_transit" => "Em trânsito",
        "lost" => "Extraviado",
        "retired" => "Baixado"
      }.freeze

      # Máquina de estados da situação física/operacional do ativo. A disponibilidade futura é
      # derivada das alocações, não deste estado.
      ASSET_TRANSITIONS = {
        "available" => %w[checked_out in_inspection in_maintenance in_transit lost retired],
        "checked_out" => %w[available in_inspection lost],
        "in_inspection" => %w[available in_maintenance lost retired],
        "in_maintenance" => %w[available in_inspection retired],
        "in_transit" => %w[available lost],
        "lost" => %w[in_inspection retired],
        "retired" => []
      }.freeze

      # Estados que impedem novas alocações até `unavailable_until` (ou indefinidamente).
      OPERATIONALLY_BLOCKED = %w[in_inspection in_maintenance in_transit].freeze
      NOT_ALLOCATABLE = %w[lost retired].freeze

      Asset = Data.define(:id, :organization_id, :product_id, :branch_id, :tag, :serial_number, :condition, :status,
                          :unavailable_until, :acquisition_cost, :acquired_on, :notes, :version) do
        def self.build(id:, organization_id:, product_id:, branch_id:, tag:, serial_number: nil, condition: "good",
                       acquisition_cost: Money.zero, acquired_on: nil, notes: nil)
          clean_tag = tag.to_s.strip.upcase
          unless clean_tag.match?(/\A[A-Z0-9][A-Z0-9-]{0,39}\z/)
            raise ValidationError.field("patrimonio",
                                        "use letras, números e hífen (até 40)")
          end
          raise ValidationError.field("condicao", "condição inválida") unless CONDITIONS.key?(condition)
          raise ValidationError.field("custo_aquisicao", "não pode ser negativo") if acquisition_cost.negative?

          new(id: id, organization_id: organization_id, product_id: product_id, branch_id: branch_id, tag: clean_tag,
              serial_number: Organizations::Text.optional(serial_number, max: 80), condition: condition, status: "available",
              unavailable_until: nil, acquisition_cost: acquisition_cost, acquired_on: acquired_on,
              notes: Organizations::Text.optional(notes), version: 1)
        end

        def can_transition_to?(target) = ASSET_TRANSITIONS.fetch(status).include?(target)

        def transition_to(target, unavailable_until: nil, condition: self.condition)
          raise InvalidTransition.new("ativo", status, target) unless can_transition_to?(target)

          until_value = OPERATIONALLY_BLOCKED.include?(target) ? unavailable_until : nil
          with(status: target, unavailable_until: until_value, condition: condition, version: version + 1)
        end

        def allocatable? = !NOT_ALLOCATABLE.include?(status)
        def operationally_blocked? = OPERATIONALLY_BLOCKED.include?(status)
        def status_label = ASSET_STATUSES.fetch(status)
        def condition_label = CONDITIONS.fetch(condition)
      end

      StockPool = Data.define(:id, :organization_id, :product_id, :branch_id, :total_quantity) do
        def adjust(delta)
          total = total_quantity + delta
          raise ValidationError.field("quantidade", "o estoque não pode ficar negativo") if total.negative?

          with(total_quantity: total)
        end
      end
    end
  end
end
