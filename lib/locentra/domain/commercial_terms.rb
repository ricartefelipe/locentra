# frozen_string_literal: true

module Locentra
  module Domain
    # Condições comerciais da organização: cadastro de cupons (com usos derivados da situação da
    # reserva), condições negociadas por cliente com vigência e encerramento único, e catálogo de
    # tarifas adicionais com regras de autorização para valores diferentes do padrão. Semântica em
    # docs/PRECIFICACAO.md e docs/modulos/condicoes-comerciais.md.
    module Pricing
      COUPON_KINDS = { "percent" => "Percentual", "fixed" => "Valor fixo" }.freeze
      COUPON_STATUSES = { "active" => "Vigente", "scheduled" => "Agendado", "expired" => "Expirado", "exhausted" => "Esgotado",
                          "inactive" => "Desativado" }.freeze
      AGREEMENT_STATUSES = { "active" => "Vigente", "scheduled" => "Agendada", "expired" => "Expirada", "ended" => "Encerrada" }.freeze
      FEE_STATUSES = { "active" => "Ativa", "inactive" => "Inativa" }.freeze
      REDEMPTION_STATES = { "active" => "Ativo", "released_cancelled" => "Liberado: reserva cancelada",
                            "released_expired" => "Liberado: bloqueio temporário expirado" }.freeze
      MAX_FEES = 10
      MAX_REDEMPTIONS = 1_000_000
      PAST_TOLERANCE = 86_400 # segundos: instantes informados até 24 h no passado são ajustados para "agora"
      ACTIVE_USE_STATUSES = %w[requested confirmed in_progress completed].freeze
      MAX_AGREEMENT_BPS = 9000

      # Formato dos códigos de cupom e de tarifa (mesmas expressões das CHECKs do banco).
      module Codes
        COUPON = /\A[A-Z0-9][A-Z0-9_-]{2,39}\z/
        FEE = /\A[A-Z0-9][A-Z0-9_-]{1,29}\z/

        module_function

        # Normalização leniente para buscas (campo "Cupom", referências na CLI e na API).
        def normalize(value) = value.to_s.strip.upcase

        def coupon!(value, field = "codigo") = check!(value, field, COUPON, 3, 40)

        def fee!(value, field = "codigo") = check!(value, field, FEE, 2, 30)

        # Códigos no formato de identificador (UUID) são recusados: as referências aceitam os dois.
        def check!(value, field, pattern, min, max)
          code = normalize(value)
          raise ValidationError.field(field, "não use o formato de identificador") if Identifier.valid?(code.downcase)

          message = "use de #{min} a #{max} caracteres: letras sem acento, números, hífen ou sublinhado"
          raise ValidationError.field(field, message) unless code.match?(pattern)

          code
        end
      end

      # Estado de um uso de cupom, derivado da situação da reserva (mesma regra da SQL e do gatilho do
      # banco): o uso libera-se sozinho no cancelamento e na expiração, sem escrita.
      module Redemptions
        # Carência do limite de usos, em segundos. Uma confirmação que leu o relógio antes do vencimento
        # do bloqueio pode gravar a reserva como confirmada depois dele; até o COMMIT, quem conta ainda vê
        # o bloqueio vencido. Para o limite, o bloqueio continua contando durante a carência, maior que a
        # duração de uma transação (instruções até 15 s, ociosidade em transação até 60 s) e que a
        # diferença de relógio entre instâncias. A situação exibida do uso não usa a carência.
        LIMIT_GRACE = 300

        module_function

        def state(reservation_status, hold_expires_at, now)
          return "active" if ACTIVE_USE_STATUSES.include?(reservation_status)
          return "active" if reservation_status == "held" && hold_expires_at && hold_expires_at > now
          return "released_cancelled" if reservation_status == "cancelled"

          "released_expired"
        end

        def active?(reservation_status, hold_expires_at, now) = state(reservation_status, hold_expires_at, now) == "active"

        # Instante de referência da contagem para o limite: o bloqueio vencido há menos que a carência conta.
        def limit_reference(now) = now - LIMIT_GRACE

        def counts_toward_limit?(reservation_status, hold_expires_at, now)
          active?(reservation_status, hold_expires_at, limit_reference(now))
        end
      end

      # Validações compartilhadas pelos cadastros: erros acumulados por campo, instantes em UTC e
      # inteiros vindos de formulário, CLI ou API.
      module Input
        module_function

        def instant(value)
          return nil if value.nil?
          raise ArgumentError, "instante deve ser Time" unless value.is_a?(Time)

          value.getutc
        end

        def integer(value, field, message)
          return nil if value.nil? || value.to_s.strip.empty?
          return value if value.is_a?(Integer)
          raise ValidationError.field(field, message) unless value.is_a?(String)

          Integer(value.strip, 10)
        rescue ArgumentError
          raise ValidationError.field(field, message)
        end

        def cents(value, field, message)
          value.is_a?(Money) ? value.cents : integer(value, field, message)
        end

        # Executa as validações de cada campo e reúne todas as mensagens num único ValidationError.
        def collect
          errors = {}
          add = lambda do |_field, &block|
            block.call
          rescue ValidationError => e
            e.errors.each { |key, messages| (errors[key] ||= []).concat(Array(messages)) }
            nil
          end
          result = yield add
          raise ValidationError, errors unless errors.empty?

          result
        end

        def fail!(field, message) = raise(ValidationError.field(field, message))

        # Instante informado para início ou encerramento: vazio é agora; até 24 h no passado é ajustado
        # para agora (formulário aberto há algum tempo, segundos cortados); antes disso é recusado.
        def not_before_now(value, now, field, message)
          at = instant(value)
          return now if at.nil? || (at < now && at >= now - PAST_TOLERANCE)
          raise ValidationError.field(field, message) if at < now

          at
        end
      end

      # Regras de cadastro de cupons. Código, tipo e valor não mudam depois de criados.
      module Coupons
        EDITABLE = %i[description valid_from valid_until max_redemptions min_subtotal_cents].freeze
        TRACKED = %i[description valid_from valid_until max_redemptions min_subtotal_cents active].freeze
        MAX_MESSAGE = "entre 1 e #{Pricing.count_label(MAX_REDEMPTIONS)}".freeze

        module_function

        # value: pontos-base (percent, 1..10.000) ou centavos (fixed, 1..Money::MAX_CENTS).
        def build(id:, organization_id:, code:, kind:, value:, description:, valid_from:, valid_until:, max_redemptions:,
                  min_subtotal_cents:, created_by:, now:)
          attrs = Input.collect do |check|
            {
              code: check.call("codigo") { Codes.coupon!(code) },
              kind: check.call("tipo") { kind!(kind) },
              value: check.call("valor") { value!(kind.to_s, value) },
              description: check.call("descricao") { description!(description) },
              valid_from: Input.instant(valid_from), valid_until: Input.instant(valid_until),
              max_redemptions: check.call("maximo_usos") { max_redemptions!(max_redemptions) },
              min_subtotal_cents: check.call("subtotal_minimo") { min_subtotal!(min_subtotal_cents) }
            }.tap { |data| check.call("valido_ate") { validity!(data[:valid_from], data[:valid_until], now, future: true) } }
          end
          Coupon.new(id: id, organization_id: organization_id, **attrs, redemptions: 0, active: true, created_by: created_by, created_at: now,
                     updated_at: now, deactivated_at: nil, lock_version: 1, total_redemptions: 0, legacy_redemptions: 0)
        end

        # Somente as chaves presentes mudam; nil limpa descrição, vigência e máximo, e vale 0 no subtotal
        # mínimo. O estado resultante é validado por inteiro (inclusive cupons da 1.0.0 com fim anterior
        # ao início ou máximo acima do limite): o erro sai no campo a corrigir. A ativação e a desativação
        # não passam por aqui e valem para qualquer cupom.
        def revise(coupon, attrs, now:)
          unknown = attrs.keys - EDITABLE
          raise ArgumentError, "campos não editáveis: #{unknown.join(", ")}" unless unknown.empty?

          changes = Input.collect do |check|
            data = {}
            data[:description] = check.call("descricao") { description!(attrs[:description]) } if attrs.key?(:description)
            data[:valid_from] = Input.instant(attrs[:valid_from]) if attrs.key?(:valid_from)
            data[:valid_until] = Input.instant(attrs[:valid_until]) if attrs.key?(:valid_until)
            data[:max_redemptions] = check.call("maximo_usos") { max_redemptions!(attrs[:max_redemptions]) } if attrs.key?(:max_redemptions)
            data[:min_subtotal_cents] = check.call("subtotal_minimo") { min_subtotal!(attrs[:min_subtotal_cents]) } if attrs.key?(:min_subtotal_cents)
            revised = coupon.with(**data)
            check.call("valido_ate") do
              validity!(revised.valid_from, revised.valid_until, now, future: revised.valid_until != coupon.valid_until)
            end
            check.call("maximo_usos") { max_redemptions!(revised.max_redemptions) } unless attrs.key?(:max_redemptions)
            check.call("maximo_usos") { below_active!(revised) }
            data
          end
          revised = coupon.with(**changes)
          return coupon if same?(coupon, revised)

          revised.with(updated_at: now, lock_version: coupon.lock_version + 1)
        end

        def set_active(coupon, active, now:)
          return coupon if coupon.active == active

          coupon.with(active: active, deactivated_at: active ? nil : now, updated_at: now, lock_version: coupon.lock_version + 1)
        end

        # Diferenças entre duas versões do cupom (instantes em ISO 8601), para a auditoria.
        def changes(before, after)
          TRACKED.each_with_object({}) do |field, diff|
            old_value = before.public_send(field)
            new_value = after.public_send(field)
            diff[field.to_s] = [serialize(old_value), serialize(new_value)] unless old_value == new_value
          end
        end

        def serialize(value) = value.is_a?(Time) ? value.getutc.iso8601 : value

        def same?(before, after) = TRACKED.all? { |field| before.public_send(field) == after.public_send(field) }

        def description!(value) = Organizations::Text.optional!(value, "descricao", max: 200)

        def kind!(kind)
          raise ValidationError.field("tipo", "use percent ou fixed") unless COUPON_KINDS.key?(kind.to_s)

          kind.to_s
        end

        def value!(kind, value)
          case kind
          when "percent"
            bps = Input.integer(value, "valor", "entre 0,01% e 100%")
            Input.fail!("valor", "entre 0,01% e 100%") unless bps&.between?(1, 10_000)
            bps
          when "fixed"
            cents = Input.cents(value, "valor", "valor positivo")
            Input.fail!("valor", "valor positivo") unless cents&.between?(1, Money::MAX_CENTS)
            cents
          end
        end

        def max_redemptions!(value)
          number = Input.integer(value, "maximo_usos", MAX_MESSAGE)
          Input.fail!("maximo_usos", MAX_MESSAGE) unless number.nil? || number.between?(1, MAX_REDEMPTIONS)
          number
        end

        def min_subtotal!(value)
          cents = Input.cents(value, "subtotal_minimo", "0 ou positivo") || 0
          Input.fail!("subtotal_minimo", "0 ou positivo") unless cents.between?(0, Money::MAX_CENTS)
          cents
        end

        # O fim, quando informado, é posterior ao início; na criação (ou quando o fim muda), também ao
        # instante atual. O início pode estar no passado: significa "já vigente".
        def validity!(from, to, now, future:)
          return if to.nil?

          Input.fail!("valido_ate", "deve ser posterior ao início da vigência") if from && to <= from
          Input.fail!("valido_ate", "não pode estar no passado") if future && to <= now
        end

        def below_active!(coupon)
          return if coupon.max_redemptions.nil? || coupon.max_redemptions >= coupon.redemptions

          Input.fail!("maximo_usos", "não pode ser menor que os usos ativos (#{Pricing.count_label(coupon.redemptions)})")
        end
      end

      # Condição negociada: desconto por cliente, geral ou de um produto, com vigência semiaberta
      # [início, fim) e encerramento único (imediato ou agendado). Não muda depois de criada.
      AGREEMENT_START_MESSAGE = "o início não pode estar mais de 24 horas no passado; deixe em branco para valer a partir de agora"
      AGREEMENT_END_MESSAGE = "o encerramento não pode estar mais de 24 horas no passado; deixe em branco para encerrar agora"

      Agreement = Data.define(:id, :organization_id, :customer_id, :product_id, :discount_bps, :valid_from, :valid_until, :notes,
                              :created_by, :created_at, :ended_at, :ended_by, :end_reason) do
        def self.build(id:, organization_id:, customer_id:, product_id:, discount_bps:, valid_from:, valid_until:, notes:, created_by:, now:)
          attrs = Input.collect do |check|
            starts = check.call("valido_de") { Input.not_before_now(valid_from, now, "valido_de", AGREEMENT_START_MESSAGE) } || now
            {
              discount_bps: check.call("desconto") { discount!(discount_bps) }, valid_from: starts,
              valid_until: check.call("valido_ate") { ends!(Input.instant(valid_until), starts, now) },
              notes: check.call("observacoes") { Organizations::Text.optional!(notes, "observacoes", max: 500) }
            }
          end
          new(id: id, organization_id: organization_id, customer_id: customer_id, product_id: product_id, **attrs, created_by: created_by,
              created_at: now, ended_at: nil, ended_by: nil, end_reason: nil)
        end

        def self.discount!(value)
          bps = Input.integer(value, "desconto", "entre 0,01% e 90%")
          Input.fail!("desconto", "entre 0,01% e 90%") unless bps&.between?(1, MAX_AGREEMENT_BPS)
          bps
        end

        # O início nunca fica antes do instante atual (é ajustado para agora), então um fim posterior ao
        # início também é posterior ao instante atual; a mensagem aponta o limite que o usuário vê.
        def self.ends!(ends, starts, now)
          return ends if ends.nil? || ends > starts

          Input.fail!("valido_ate", starts > now ? "deve ser posterior ao início da vigência" : "deve ser posterior ao momento atual")
        end

        # Maior desconto; em empate, a condição do produto; depois o identificador (mesma ordem da SQL).
        def self.best(candidates)
          candidates.compact.min_by { |a| [-a.discount_bps, a.product_id ? 0 : 1, a.id.to_s] }
        end

        def scope = product_id ? "product" : "general"

        def effective_end = [valid_until, ended_at].compact.min

        def status(now)
          if ended_at && ended_at <= now then "ended"
          elsif valid_until && valid_until <= now then "expired"
          elsif valid_from > now then "scheduled"
          else "active"
          end
        end

        def effective?(now) = status(now) == "active"

        def end_scheduled?(now) = !ended_at.nil? && ended_at > now

        # Encerramento único: imediato (at vazio ou até 24 h no passado) ou agendado. Encerrar uma
        # condição agendada antes do início deixa a vigência vazia. `zone` formata o fim nas mensagens.
        def end_at(now:, at:, by:, reason:, zone: nil)
          current = status(now)
          raise InvalidTransition.new("condição negociada", current, "ended") if ended_at || current == "expired"

          attrs = Input.collect do |check|
            {
              end_reason: check.call("motivo") { Organizations::Text.required(reason, "motivo", min: 3, max: 500) },
              ended_at: check.call("encerrar_em") { end_instant!(at, now, zone) }
            }
          end
          with(**attrs, ended_by: by)
        end

        def to_snapshot
          { "id" => id, "scope" => scope, "product_id" => product_id, "discount_bps" => discount_bps,
            "valid_from" => valid_from&.getutc&.iso8601, "valid_until" => valid_until&.getutc&.iso8601,
            "ended_at" => ended_at&.getutc&.iso8601 }
        end

        private

        def end_instant!(at, now, zone)
          instant = Input.not_before_now(at, now, "encerrar_em", AGREEMENT_END_MESSAGE)
          limit = effective_end
          if limit && instant >= limit
            Input.fail!("encerrar_em", "a condição já termina em #{zone ? zone.format_local(limit) : limit.getutc.iso8601}")
          end
          instant
        end
      end

      # Tarifa adicional do catálogo da organização. O código não muda; nome, descrição e valor padrão,
      # sim, sem afetar documentos já registrados.
      FEE_EDITABLE = %i[name description default_amount].freeze

      Fee = Data.define(:id, :organization_id, :code, :name, :description, :default_amount, :active, :lock_version, :created_by,
                        :created_at, :updated_at, :deactivated_at) do
        def self.build(id:, organization_id:, code:, name:, description:, default_amount:, created_by:, now:)
          attrs = Input.collect do |check|
            { code: check.call("codigo") { Codes.fee!(code) }, name: check.call("nome") { name!(name) },
              description: check.call("descricao") { description!(description) },
              default_amount: check.call("valor_padrao") { amount!(default_amount) } }
          end
          new(id: id, organization_id: organization_id, **attrs, active: true, lock_version: 1, created_by: created_by, created_at: now,
              updated_at: now, deactivated_at: nil)
        end

        def self.name!(value) = Organizations::Text.required(value, "nome", min: 2, max: 120)
        def self.description!(value) = Organizations::Text.optional!(value, "descricao", max: 500)

        def self.amount!(value)
          amount = value.is_a?(Integer) ? Money.new(value) : value
          Input.fail!("valor_padrao", "valor positivo") unless amount.is_a?(Money) && amount.positive?
          amount
        end

        # Chaves parciais (:name, :description, :default_amount); sem mudança devolve a própria tarifa.
        def revise(attrs, now:)
          unknown = attrs.keys - FEE_EDITABLE
          raise ArgumentError, "campos não editáveis: #{unknown.join(", ")}" unless unknown.empty?

          changes = Input.collect do |check|
            data = {}
            data[:name] = check.call("nome") { Fee.name!(attrs[:name]) } if attrs.key?(:name)
            data[:description] = check.call("descricao") { Fee.description!(attrs[:description]) } if attrs.key?(:description)
            data[:default_amount] = check.call("valor_padrao") { Fee.amount!(attrs[:default_amount]) } if attrs.key?(:default_amount)
            data
          end
          revised = with(**changes)
          return self if revised == self

          revised.with(updated_at: now, lock_version: lock_version + 1)
        end

        def set_active(active, now:)
          return self if self.active == active

          with(active: active, deactivated_at: active ? nil : now, updated_at: now, lock_version: lock_version + 1)
        end

        def status = active ? "active" : "inactive"

        def changes(after)
          FEE_EDITABLE.each_with_object({}) do |field, diff|
            old_value = public_send(field)
            new_value = after.public_send(field)
            next if old_value == new_value

            key = field == :default_amount ? "default_amount_cents" : field.to_s
            diff[key] = field == :default_amount ? [old_value.cents, new_value.cents] : [old_value, new_value]
          end
        end
      end

      # Pedido de tarifa num documento: do catálogo (fee_id; amount nil = valor padrão vigente) ou
      # avulsa (descrição e valor).
      FeeRequest = Data.define(:fee_id, :amount, :description) do
        def self.catalog(fee_id:, amount: nil)
          new(fee_id: Identifier.parse(fee_id, "tarifas"), amount: amount.nil? ? nil : positive!(amount), description: nil)
        end

        def self.custom(description:, amount:)
          new(fee_id: nil, amount: positive!(amount), description: Organizations::Text.required(description, "tarifas", min: 2, max: 120))
        end

        def self.positive!(amount)
          Input.fail!("tarifas", "o valor da tarifa deve ser positivo") unless amount.is_a?(Money) && amount.positive?
          amount
        end

        def custom? = fee_id.nil?
      end

      # Resolução das tarifas de um documento contra o catálogo, com autorização de ajustes.
      module Fees
        Resolution = Data.define(:entries, :overrides)
        OVERRIDE_PERMISSION = "valor diferente do padrão ou tarifa avulsa exige a permissão de ajustar tarifas " \
                              "(gerente, administrador ou proprietário)"

        module_function

        # catalog: { fee_id => Fee } da organização (inclui as tarifas da versão anterior, mesmo inativas).
        # previous: entradas "fees" do snapshot da versão anterior do orçamento; uma entrada idêntica
        # (mesma tarifa e valor, ou avulsa com a mesma descrição e valor) já foi autorizada e é mantida
        # sem nova autorização, mesmo com a tarifa inativa. Cada entrada anterior autoriza no máximo um
        # pedido: a cópia excedente é um ajuste novo.
        # may_override: permissão fees.override do ator; reduction_limit_bps: limite de desconto do papel.
        def resolve(requests, catalog:, may_override:, reduction_limit_bps:, previous: [])
          Input.fail!("tarifas", "no máximo #{MAX_FEES} tarifas") if requests.size > MAX_FEES
          seen = {}
          remaining = previous.dup
          resolved = requests.map do |request|
            request.custom? ? custom_entry(request, remaining) : catalog_entry(request, catalog, remaining, seen)
          end
          overrides = resolved.filter_map { |entry, override| override && entry }
          authorize!(overrides, may_override, reduction_limit_bps)
          Resolution.new(entries: resolved.map(&:first).freeze, overrides: overrides.freeze)
        end

        def catalog_entry(request, catalog, previous, seen)
          fee = catalog[request.fee_id] || raise(NotFound.new("tarifa", feminine: true))
          Input.fail!("tarifas", "a tarifa #{fee.code} foi informada mais de uma vez") if seen[fee.id]
          seen[fee.id] = true
          amount = request.amount || fee.default_amount
          kept = take!(previous) { |p| p["fee_id"] == fee.id && p["amount_cents"] == amount.cents }
          Input.fail!("tarifas", "a tarifa #{fee.code} está inativa") unless fee.active || kept
          entry = { "fee_id" => fee.id, "code" => fee.code, "description" => fee.name, "amount_cents" => amount.cents,
                    "default_amount_cents" => fee.default_amount.cents, "source" => "catalog" }
          [entry, amount != fee.default_amount && !kept]
        end

        def custom_entry(request, previous)
          kept = take!(previous) do |p|
            p["fee_id"].nil? && p["description"] == request.description && p["amount_cents"] == request.amount.cents
          end
          entry = { "fee_id" => nil, "code" => nil, "description" => request.description, "amount_cents" => request.amount.cents,
                    "default_amount_cents" => nil, "source" => "custom" }
          [entry, !kept]
        end

        # Remove de `remaining` a primeira entrada que satisfaz o bloco; verdadeiro quando havia uma.
        def take!(remaining, &)
          index = remaining.index(&)
          return false if index.nil?

          remaining.delete_at(index)
          true
        end

        def authorize!(overrides, may_override, limit_bps)
          return if overrides.empty?
          raise AccessDenied, "#{OVERRIDE_PERMISSION}: #{overrides.map { |o| describe(o) }.join("; ")}" unless may_override

          overrides.each do |entry|
            default = entry["default_amount_cents"]
            next if default.nil? || entry["amount_cents"] >= default
            next if (default - entry["amount_cents"]) * 10_000 <= limit_bps * default

            raise AccessDenied, "redução da tarifa #{entry["code"]} acima do limite autorizado para o papel (#{Percent.label(limit_bps)})"
          end
        end

        def describe(entry)
          amount = Money.new(entry["amount_cents"]).format_brl
          return "#{entry["description"]} #{amount} (avulsa)" if entry["default_amount_cents"].nil?

          "#{entry["description"]} #{amount} (padrão #{Money.new(entry["default_amount_cents"]).format_brl})"
        end
      end
    end
  end
end
