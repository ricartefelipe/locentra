# frozen_string_literal: true

module Locentra
  module Domain
    # Motor de disponibilidade: funções puras sobre períodos semiabertos.
    #
    # O PostgreSQL garante as invariantes sob concorrência (exclusion constraints para ativos
    # individuais e locks de linha para estoque quantitativo). Este módulo define as regras
    # que essas garantias aplicam e é a fonte única do cálculo de ocupação.
    module Availability
      # Ocupação de uma quantidade de unidades intercambiáveis durante um período.
      Occupancy = Data.define(:period, :quantity) do
        def initialize(period:, quantity:)
          raise ArgumentError, "período inválido" unless period.is_a?(Period)
          raise ArgumentError, "quantidade deve ser inteira e positiva" unless quantity.is_a?(Integer) && quantity.positive?

          super
        end
      end

      # Trecho da linha do tempo com ocupação constante.
      Segment = Data.define(:period, :quantity)

      # Cálculo de ocupação simultânea por varredura de eventos.
      module Peak
        module_function

        # Maior ocupação simultânea dentro de `window`. Intervalos que apenas se tocam
        # (fim de um igual ao início do outro) não se somam.
        def within(window, occupancies)
          running = 0
          peak = 0
          events(window, occupancies).map(&:last).each do |delta|
            running += delta
            peak = running if running > peak
          end
          peak
        end

        # Linha do tempo de ocupação dentro da janela, em trechos de valor constante.
        def timeline(window, occupancies)
          boundaries = [window.starts_at.to_i, window.ends_at.to_i]
          relevant = occupancies.select { |occ| occ.period.overlaps?(window) }
          relevant.each do |occ|
            boundaries << [occ.period.starts_at.to_i, window.starts_at.to_i].max
            boundaries << [occ.period.ends_at.to_i, window.ends_at.to_i].min
          end
          points = boundaries.uniq.sort
          points.each_cons(2).map do |from, to|
            slice = Period.new(Time.at(from).utc, Time.at(to).utc)
            quantity = relevant.sum { |occ| occ.period.overlaps?(slice) ? occ.quantity : 0 }
            Segment.new(period: slice, quantity: quantity)
          end
        end

        # Eventos (instante, delta) recortados à janela. Em empates, saídas (-) antes de
        # entradas (+), coerente com o fim exclusivo.
        def events(window, occupancies)
          list = []
          occupancies.each do |occ|
            next unless occ.period.overlaps?(window)

            list << [[occ.period.starts_at.to_i, window.starts_at.to_i].max, occ.quantity]
            list << [[occ.period.ends_at.to_i, window.ends_at.to_i].min, -occ.quantity]
          end
          list.sort_by! { |instant, delta| [instant, delta] }
        end
      end

      # Capacidade de um estoque quantitativo (produto em uma filial) diante das ocupações.
      class StockLedger
        attr_reader :capacity, :occupancies

        def initialize(capacity:, occupancies: [])
          raise ArgumentError, "capacidade deve ser inteira e não negativa" unless capacity.is_a?(Integer) && !capacity.negative?

          @capacity = capacity
          @occupancies = occupancies.dup.freeze
          freeze
        end

        def peak(window)
          Peak.within(window, occupancies)
        end

        def available(window)
          [capacity - peak(window), 0].max
        end

        def fits?(window, quantity)
          quantity <= available(window)
        end

        # Novo ledger com a ocupação adicional, rejeitando sobrealocação.
        def reserve(window, quantity)
          raise Unavailable, [{ "requested" => quantity, "available" => available(window) }] unless fits?(window, quantity)

          StockLedger.new(capacity: capacity, occupancies: occupancies + [Occupancy.new(period: window, quantity: quantity)])
        end
      end

      # Agenda de um ativo individual: períodos já bloqueados e indisponibilidade operacional.
      class AssetSchedule
        attr_reader :asset_id, :busy, :unavailable_until

        # `allocatable` falso indica perda, baixa ou desativação.
        # `unavailable_until` nil com `operationally_blocked` verdadeiro bloqueia indefinidamente.
        def initialize(asset_id:, busy: [], allocatable: true, operationally_blocked: false, unavailable_until: nil)
          @asset_id = asset_id
          @busy = busy.dup.freeze
          @allocatable = allocatable
          @operationally_blocked = operationally_blocked
          @unavailable_until = unavailable_until
          freeze
        end

        def free?(window)
          return false unless @allocatable
          return false if operationally_blocked_for?(window)

          busy.none? { |period| period.overlaps?(window) }
        end

        private

        def operationally_blocked_for?(window)
          return false unless @operationally_blocked
          return true if unavailable_until.nil?

          window.starts_at < unavailable_until
        end
      end

      # Seleção determinística de ativos livres: menor identificador primeiro, sem repetir unidades.
      module AssetPicker
        module_function

        def pick(window, schedules, quantity, exclude: [])
          free = schedules.reject { |s| exclude.include?(s.asset_id) }.select { |s| s.free?(window) }.map(&:asset_id).sort
          free.first(quantity)
        end

        def available_count(window, schedules)
          schedules.count { |schedule| schedule.free?(window) }
        end
      end

      # Especificação mínima de produto para expansão de demanda.
      ProductSpec = Data.define(:id, :tracking, :components) do
        def initialize(id:, tracking:, components: [])
          raise ArgumentError, "rastreamento inválido: #{tracking}" unless %w[serialized bulk kit].include?(tracking)

          super(id: id, tracking: tracking, components: components.freeze)
        end

        def kit? = tracking == "kit"
      end

      # Demanda de um componente físico, com a linha de origem e o kit pelo qual foi pedida.
      ComponentDemand = Data.define(:product_id, :quantity, :line_index, :kit_id)

      # Expande kits em componentes e agrega a demanda por produto físico, de modo que um
      # componente pedido diretamente e também por meio de um kit seja verificado uma só vez
      # contra a mesma capacidade.
      class DemandExpander
        def initialize(products)
          @products = products
        end

        # lines: [{product_id:, quantity:}]
        def expand(lines)
          lines.each_with_index.flat_map do |line, index|
            product = fetch(line.fetch(:product_id))
            quantity = line.fetch(:quantity)
            raise ValidationError.field("quantidade", "deve ser inteira e positiva") unless quantity.is_a?(Integer) && quantity.positive?

            if product.kit?
              product.components.map do |component|
                component_product = fetch(component.fetch(:product_id))
                raise InvariantViolation, "kit não pode conter outro kit" if component_product.kit?

                ComponentDemand.new(product_id: component_product.id, quantity: component.fetch(:quantity) * quantity,
                                    line_index: index, kit_id: product.id)
              end
            else
              [ComponentDemand.new(product_id: product.id, quantity: quantity, line_index: index, kit_id: nil)]
            end
          end
        end

        def aggregate(lines)
          expand(lines).each_with_object(Hash.new(0)) { |demand, totals| totals[demand.product_id] += demand.quantity }
        end

        private

        def fetch(id)
          @products.fetch(id) { raise NotFound, "produto" }
        end
      end

      # Validação estrutural de composição de kits.
      module KitRules
        module_function

        def validate!(kit_id, components, products)
          raise ValidationError.field("componentes", "informe ao menos um componente") if components.empty?

          ids = components.map { |c| c.fetch(:product_id) }
          raise ValidationError.field("componentes", "componente repetido") if ids.uniq.size != ids.size
          raise ValidationError.field("componentes", "um kit não pode conter a si mesmo") if ids.include?(kit_id)

          components.each do |component|
            product = products.fetch(component.fetch(:product_id)) { raise NotFound, "produto componente" }
            raise ValidationError.field("componentes", "kits não podem ser aninhados") if product.kit?

            quantity = component.fetch(:quantity)
            raise ValidationError.field("componentes", "quantidade inválida") unless quantity.is_a?(Integer) && quantity.positive?
          end
          true
        end
      end
    end
  end
end
