# frozen_string_literal: true

require_relative "output"
require_relative "command_support"
require_relative "../commercial_terms_serializers"

module Locentra
  module Interfaces
    module CLI
      # Comandos de condições comerciais da CLI operacional: consulta e cadastro de cupons, consulta de
      # tarifas adicionais e consulta, cadastro e encerramento de condições negociadas. Usam os mesmos
      # casos de uso, permissões e auditoria da interface web e da API; a saída JSON tem os mesmos campos
      # da API v1 (CommercialTermsSerializers). Edição de cupom e gestão de tarifas ficam na web e na API.
      class CommercialTermsCommands
        include CommandSupport

        F = Formatting
        CS = CommercialTermsSerializers
        P = Domain::Pricing
        HANDLERS = %i[coupons_list coupons_show coupons_create coupons_deactivate coupons_reactivate fees_list fees_show
                      agreements_list agreements_create agreements_end].freeze
        COUPON_HEADERS = ["Código", "Descrição", "Desconto", "Vigência", "Usos", "Subtotal mínimo", "Situação"].freeze
        REDEMPTION_HEADERS = ["Reserva", "Cliente", "Subtotal", "Desconto", "Usado em", "Situação"].freeze
        AGREEMENT_HEADERS = %w[Id Escopo Desconto Vigência Situação Observações].freeze

        def self.handles?(handler) = HANDLERS.include?(handler)

        def initialize(system:, actor:)
          @system = system
          @actor = actor
        end

        def run(invocation)
          options = invocation.options
          argument = invocation.argument
          case invocation.command.handler
          when :coupons_list then coupons_list(options)
          when :coupons_show then coupons_show(argument, options)
          when :coupons_create then coupons_create(options)
          when :coupons_deactivate then coupons_toggle(argument, false)
          when :coupons_reactivate then coupons_toggle(argument, true)
          when :fees_list then fees_list(options)
          when :fees_show then fees_show(argument)
          when :agreements_list then agreements_list(options)
          when :agreements_create then agreements_create(options)
          when :agreements_end then agreements_end(argument, options)
          end
        end

        private

        def now = @system.clock.now

        # Cupons ------------------------------------------------------------------------------------

        def coupons_list(options)
          page = uc(:list_coupons).call(@actor, status: options[:coupon_status], search: options[:term_search],
                                                sort: options[:coupon_sort] || "code", limit: options[:limit], offset: options[:offset])
          data = { "data" => page.items.map { |row| CS.coupon(row[:coupon], row[:status]) }, "pagination" => pagination(page) }
          return Result.ok(data, ["Nenhum cupom encontrado."]) if page.items.empty?

          rows = page.items.map do |row|
            coupon = row[:coupon]
            [coupon.code, coupon.description, discount(coupon), validity(coupon.valid_from, coupon.valid_until), coupon.usage_text,
             minimum(coupon), P::COUPON_STATUSES.fetch(row[:status])]
          end
          Result.ok(data, [*F.table(COUPON_HEADERS, rows), "", shown_line(page)])
        end

        def coupons_show(reference, options)
          details = uc(:get_coupon).call(@actor, reference)
          uses = uc(:list_coupon_redemptions).call(@actor, details[:coupon].id, limit: options[:limit], offset: options[:offset])
          scopes = { reservations: Application::Authorizer.allowed?(@actor, "reservations.read"),
                     customers: Application::Reservations::ListReservations.customer_names?(@actor) }
          data = { "coupon" => CS.coupon(details[:coupon], details[:status]),
                   "redemptions" => { "data" => uses.items.map { |item| CS.coupon_redemption(item, **scopes) }, "pagination" => pagination(uses) } }
          Result.ok(data, coupon_lines(details[:coupon], details[:status]) + ["", "Usos:", *redemption_lines(uses, scopes)] +
                          [toggle_hint(details[:coupon])])
        end

        def coupons_create(options)
          coupon = uc(:create_coupon).call(@actor, coupon_attrs(options))
          Result.ok({ "coupon" => CS.coupon(coupon, coupon.status(now)) },
                    ["Cupom #{coupon.code} cadastrado.", *coupon_lines(coupon, coupon.status(now)).drop(1),
                     "Consultar: bin/locentra coupons show #{coupon.code}"])
        end

        # Desativação e reativação. No mesmo estado, a operação é nula: nada é gravado nem auditado.
        def coupons_toggle(reference, active)
          result = uc(:set_coupon_active).call(@actor, reference, active: active)
          coupon = result.record
          state = active ? "ativo" : "desativado"
          line = if !result.changed then "O cupom #{coupon.code} já estava #{state}; nenhuma alteração."
                 elsif active then "Cupom #{coupon.code} reativado."
                 else "Cupom #{coupon.code} desativado. Reservas já registradas não mudam."
                 end
          Result.ok({ "coupon" => CS.coupon(coupon, coupon.status(now)), "changed" => result.changed }, [line, toggle_hint(coupon)])
        end

        def coupon_attrs(options)
          P::Input.collect do |check|
            { code: options[:code], kind: options[:kind], description: options[:description], max_redemptions: options[:max_uses],
              value: check.call("valor") { coupon_value(options[:kind], options[:value]) },
              valid_from: check.call("valido_de") { options[:valid_from] && instant(options[:valid_from], "valido_de") },
              valid_until: check.call("valido_ate") { options[:valid_until] && instant(options[:valid_until], "valido_ate") },
              min_subtotal_cents: check.call("subtotal_minimo") { options[:min_subtotal] && money(options[:min_subtotal], "subtotal_minimo") } }
          end
        end

        # Percentual em pontos-base ou valor fixo em centavos, conforme o tipo; tipo inválido fica para a
        # validação do domínio.
        def coupon_value(kind, value)
          case kind
          when "percent" then Domain::Percent.parse(value, "valor")
          when "fixed" then money(value, "valor")
          end
        end

        def money(text, field)
          Domain::Money.parse(text)
        rescue Domain::ValidationError => e
          raise Domain::ValidationError.field(field, e.errors.values.flatten.first || "formato monetário inválido")
        end

        def coupon_lines(coupon, status)
          lines = ["Cupom #{coupon.code} · #{P::COUPON_STATUSES.fetch(status)}",
                   "Desconto: #{discount(coupon)} (#{P::COUPON_KINDS.fetch(coupon.kind).downcase})",
                   "Vigência: #{validity(coupon.valid_from, coupon.valid_until)} (#{zone.identifier})",
                   "Usos ativos: #{coupon.usage_text}#{"; restantes: #{P.count_label(coupon.remaining)}" if coupon.remaining}" \
                   "#{" · total de usos: #{P.count_label(coupon.total_redemptions)}" if coupon.total_redemptions}",
                   "Subtotal mínimo: #{minimum(coupon)}"]
          lines << "Descrição: #{F.clean(coupon.description)}" if coupon.description
          lines
        end

        def redemption_lines(page, scopes)
          return ["  nenhum uso registrado"] if page.items.empty?

          rows = page.items.map do |item|
            state = P::REDEMPTION_STATES.fetch(item[:state])
            state += " em #{F.time(item[:released_at], zone)}" if item[:released_at]
            [scopes[:reservations] ? item[:reservation_code] : "—", scopes[:customers] ? item[:customer_name] : "—",
             item[:subtotal].format_brl, item[:discount].format_brl, F.time(item[:redeemed_at], zone), state]
          end
          [*F.table(REDEMPTION_HEADERS, rows), "", shown_line(page)]
        end

        def toggle_hint(coupon)
          coupon.active ? "Desativar: bin/locentra coupons deactivate #{coupon.code}" : "Reativar: bin/locentra coupons reactivate #{coupon.code}"
        end

        def discount(coupon) = coupon.kind == "percent" ? Domain::Percent.label(coupon.value) : Domain::Money.new(coupon.value).format_brl

        def minimum(coupon) = coupon.min_subtotal_cents.to_i.positive? ? Domain::Money.new(coupon.min_subtotal_cents).format_brl : nil

        # Vigência semiaberta [início, fim) no fuso da organização.
        def validity(from, to)
          parts = []
          parts << "desde #{F.time(from, zone)}" if from
          parts << "até #{F.time(to, zone)}" if to
          parts.empty? ? "sem prazo" : parts.join(" ")
        end

        # Tarifas adicionais ------------------------------------------------------------------------

        def fees_list(options)
          page = uc(:list_fees).call(@actor, status: options[:fee_status], search: options[:term_search], limit: options[:limit],
                                             offset: options[:offset])
          data = { "data" => page.items.map { |fee| CS.fee(fee) }, "pagination" => pagination(page) }
          return Result.ok(data, ["Nenhuma tarifa encontrada."]) if page.items.empty?

          rows = page.items.map { |fee| [fee.code, fee.name, fee.default_amount.format_brl, P::FEE_STATUSES.fetch(fee.status)] }
          Result.ok(data, [*F.table(["Código", "Nome", "Valor padrão", "Situação"], rows), "", shown_line(page)])
        end

        def fees_show(reference)
          fee = uc(:get_fee).call(@actor, reference)[:fee]
          lines = ["Tarifa #{fee.code} · #{P::FEE_STATUSES.fetch(fee.status)}", "Nome: #{F.clean(fee.name)}",
                   "Valor padrão: #{fee.default_amount.format_brl}", "Atualizada em: #{F.time(fee.updated_at, zone)} (#{zone.identifier})"]
          lines << "Descrição: #{F.clean(fee.description)}" if fee.description
          Result.ok({ "fee" => CS.fee(fee) }, lines)
        end

        # Condições negociadas ----------------------------------------------------------------------

        def agreements_list(options)
          page = uc(:list_price_agreements).call(@actor, options[:customer], limit: options[:limit], offset: options[:offset])
          data = { "data" => page.items.map { |row| CS.price_agreement(row[:agreement], row[:status], product: row[:product]) },
                   "pagination" => pagination(page) }
          return Result.ok(data, ["Nenhuma condição negociada para este cliente."]) if page.items.empty?

          rows = page.items.map do |row|
            agreement = row[:agreement]
            [agreement.id, agreement_scope(agreement, row[:product]), Domain::Percent.label(agreement.discount_bps),
             validity(agreement.valid_from, agreement.valid_until), agreement_status(agreement, row[:status]), agreement.notes]
          end
          Result.ok(data, [*F.table(AGREEMENT_HEADERS, rows), "", shown_line(page), "Encerrar: bin/locentra agreements end ID --motivo TEXTO"])
        end

        def agreements_create(options)
          attrs = P::Input.collect do |check|
            { product: options[:agreement_product], notes: options[:notes],
              discount_bps: check.call("desconto") { Domain::Percent.parse(options[:discount], "desconto") },
              valid_from: check.call("valido_de") { options[:valid_from] && instant(options[:valid_from], "valido_de") },
              valid_until: check.call("valido_ate") { options[:valid_until] && instant(options[:valid_until], "valido_ate") } }
          end
          agreement = uc(:create_price_agreement).call(@actor, options[:customer], attrs)
          status = agreement.status(now)
          Result.ok({ "agreement" => CS.price_agreement(agreement, status) },
                    ["Condição negociada cadastrada (#{P::AGREEMENT_STATUSES.fetch(status).downcase}): #{Domain::Percent.label(agreement.discount_bps)} " \
                     "#{agreement.product_id ? "no produto #{F.clean(options[:agreement_product])}" : "em todos os produtos"}.",
                     "Vigência: #{validity(agreement.valid_from, agreement.valid_until)} (#{zone.identifier})", "Id: #{agreement.id}",
                     "Reservas e orçamentos já registrados não mudam."])
        end

        def agreements_end(agreement_id, options)
          at = options[:end_at] && instant(options[:end_at], "encerrar_em")
          agreement = uc(:end_price_agreement).call(@actor, agreement_id, reason: options[:reason], at: at)
          line = if agreement.end_scheduled?(now)
                   "Encerramento agendado para #{F.time(agreement.ended_at, zone)} (#{zone.identifier})."
                 else
                   "Condição negociada encerrada em #{F.time(agreement.ended_at, zone)} (#{zone.identifier})."
                 end
          Result.ok({ "agreement" => CS.price_agreement(agreement, agreement.status(now)) },
                    [line, "Motivo: #{F.clean(agreement.end_reason)}", "Reservas e orçamentos já registrados não mudam."])
        end

        # Sem `catalog.read`, o produto aparece apenas pelo identificador.
        def agreement_scope(agreement, product)
          return "Todos os produtos" unless agreement.product_id

          product ? "#{product[:name]} (#{product[:sku]})" : "Produto #{agreement.product_id}"
        end

        def agreement_status(agreement, status)
          label = P::AGREEMENT_STATUSES.fetch(status)
          agreement.end_scheduled?(now) ? "#{label} (encerramento agendado para #{F.time(agreement.ended_at, zone)})" : label
        end
      end
    end
  end
end
