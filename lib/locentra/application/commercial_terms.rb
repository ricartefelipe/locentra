# frozen_string_literal: true

module Locentra
  module Application
    # Cadastro de condições comerciais: cupons (com livro de usos), tarifas adicionais e condições
    # negociadas por cliente. Toda alteração é auditada na mesma transação; alterações sem mudança e
    # ativação ou desativação no mesmo estado são operações nulas (devolvem o registro, sem auditoria).
    #
    # `tx:` permite compor com a idempotência da API: a transação já está aberta e o ator foi
    # revalidado; a permissão é conferida novamente sobre o ator recebido.
    module CommercialTerms
      P = Domain::Pricing

      Result = Data.define(:record, :changed)

      module Support
        module_function

        def run(uow, actor, permission, tx, &)
          return uow.run(actor, permission, &) unless tx

          Authorizer.authorize!(actor, permission)
          yield tx, actor
        end

        # Referência de cupom: identificador (UUID) ou código (normalizado).
        def coupon(coupons, tx, reference, now:, lock: false)
          text = reference.to_s.strip
          raise Domain::NotFound, "cupom" if text.empty?

          found = if Domain::Identifier.valid?(text.downcase)
                    lock ? coupons.lock(tx, text.downcase, now: now) : coupons.find(tx, text.downcase, now: now)
                  else
                    code = P::Codes.normalize(text)
                    lock ? coupons.lock_by_code(tx, code, now: now) : coupons.find_by_code(tx, code, now: now)
                  end
          found || raise(Domain::NotFound, "cupom")
        end

        def fee(fees, tx, reference, lock: false)
          text = reference.to_s.strip
          raise Domain::NotFound.new("tarifa", feminine: true) if text.empty?

          found = if Domain::Identifier.valid?(text.downcase)
                    lock ? fees.lock(tx, text.downcase) : fees.find(tx, text.downcase)
                  else
                    code = P::Codes.normalize(text)
                    lock ? fees.lock_by_code(tx, code) : fees.find_by_code(tx, code)
                  end
          found || raise(Domain::NotFound.new("tarifa", feminine: true))
        end

        # Controle otimista: a versão é opcional (API); quando informada, precisa ser a atual.
        def stale!(record, lock_version, code, label)
          return if lock_version.to_s.strip.empty? || lock_version.to_s.strip == record.lock_version.to_s

          raise Domain::Conflict.new("#{label} foi alterad#{code == "stale_fee" ? "a" : "o"} por outra operação; revise os valores atuais",
                                     code: code)
        end

        def search!(value)
          text = value.to_s.strip
          raise Domain::ValidationError.field("busca", "até 40 caracteres") if text.length > 40

          text
        end

        def status!(value, allowed)
          return nil if value.to_s.empty?
          raise Domain::ValidationError.field("situacao", "inválida") unless allowed.key?(value.to_s)

          value.to_s
        end

        def coupon_details(coupon)
          { "code" => coupon.code }
        end
      end

      # Cupons ---------------------------------------------------------------------------------------

      class CreateCoupon
        def initialize(uow:, coupons:, audit:, clock:, ids:)
          @uow = uow
          @coupons = coupons
          @audit = audit
          @clock = clock
          @ids = ids
        end

        # attrs: code, kind, value (pontos-base ou centavos), description, valid_from, valid_until,
        # max_redemptions, min_subtotal_cents.
        def call(actor, attrs, tx: nil)
          Support.run(@uow, actor, "coupons.write", tx) do |t, current|
            now = @clock.now
            coupon = P::Coupons.build(id: @ids.uuid, organization_id: t.tenant_id!, created_by: current.audit_actor_id, now: now,
                                      code: attrs[:code], kind: attrs[:kind], value: attrs[:value], description: attrs[:description],
                                      valid_from: attrs[:valid_from], valid_until: attrs[:valid_until],
                                      max_redemptions: attrs[:max_redemptions], min_subtotal_cents: attrs[:min_subtotal_cents])
            if @coupons.insert(t, coupon).zero?
              raise Domain::Conflict.new("já existe cupom com o código #{coupon.code} (inclusive desativado)", code: "coupon_code_taken")
            end

            @audit.record(t, current, "coupon.created", "coupon", coupon.id,
                          "code" => coupon.code, "kind" => coupon.kind, "value" => coupon.value,
                          "valid_from" => coupon.valid_from&.iso8601, "valid_until" => coupon.valid_until&.iso8601,
                          "max_redemptions" => coupon.max_redemptions, "min_subtotal_cents" => coupon.min_subtotal_cents)
            coupon
          end
        end
      end

      # Edição dos campos editáveis com controle otimista (`lock_version` informado diferente do atual
      # resulta em `stale_coupon`). Os usos ativos são contados depois da trava do cupom; o novo máximo é
      # comparado com os usos que contam para o limite, com a mesma carência do resgate.
      class UpdateCoupon
        def initialize(uow:, coupons:, audit:, clock:)
          @uow = uow
          @coupons = coupons
          @audit = audit
          @clock = clock
        end

        def call(actor, reference, attrs, lock_version: nil, tx: nil)
          Support.run(@uow, actor, "coupons.write", tx) do |t, current|
            now = @clock.now
            coupon = Support.coupon(@coupons, t, reference, now: now, lock: true)
            Support.stale!(coupon, lock_version, "stale_coupon", "o cupom")
            limit_uses = attrs.key?(:max_redemptions) ? @coupons.limit_redemptions(t, coupon, now: now) : coupon.redemptions
            revised = P::Coupons.revise(coupon, attrs, now: now, limit_uses: limit_uses)
            next Result.new(record: coupon, changed: false) if revised.equal?(coupon)

            if @coupons.update(t, revised, coupon.lock_version).zero?
              raise Domain::Conflict.new("o cupom foi alterado por outra operação; revise os valores atuais", code: "stale_coupon")
            end

            @audit.record(t, current, "coupon.updated", "coupon", coupon.id, "changes" => P::Coupons.changes(coupon, revised))
            Result.new(record: revised, changed: true)
          end
        end
      end

      class SetCouponActive
        def initialize(uow:, coupons:, audit:, clock:)
          @uow = uow
          @coupons = coupons
          @audit = audit
          @clock = clock
        end

        def call(actor, reference, active:, tx: nil)
          Support.run(@uow, actor, "coupons.write", tx) do |t, current|
            now = @clock.now
            coupon = Support.coupon(@coupons, t, reference, now: now, lock: true)
            changed = P::Coupons.set_active(coupon, active, now: now)
            next Result.new(record: coupon, changed: false) if changed.equal?(coupon)

            @coupons.update(t, changed, coupon.lock_version)
            @audit.record(t, current, active ? "coupon.reactivated" : "coupon.deactivated", "coupon", coupon.id, Support.coupon_details(coupon))
            Result.new(record: changed, changed: true)
          end
        end
      end

      # Exclusão somente de cupom nunca usado (nem no livro, nem no contador da 1.0.0). A chave
      # estrangeira do livro de usos garante a regra no banco.
      class DeleteCoupon
        def initialize(uow:, coupons:, audit:, clock:)
          @uow = uow
          @coupons = coupons
          @audit = audit
          @clock = clock
        end

        def self.deletable?(coupons, tx, coupon)
          coupon.legacy_redemptions.to_i.zero? && !coupons.ever_redeemed?(tx, coupon.id)
        end

        def call(actor, reference)
          @uow.run(actor, "coupons.write") do |tx, current|
            coupon = Support.coupon(@coupons, tx, reference, now: @clock.now, lock: true)
            unless self.class.deletable?(@coupons, tx, coupon)
              raise Domain::Conflict.new("o cupom #{coupon.code} já foi usado e não pode ser excluído; desative-o", code: "coupon_in_use")
            end

            @coupons.delete(tx, coupon.id)
            @audit.record(tx, current, "coupon.deleted", "coupon", coupon.id, Support.coupon_details(coupon))
            true
          end
        end
      end

      class ListCoupons
        SORTS = %w[code -created_at valid_until].freeze

        def initialize(uow:, coupons:, clock:)
          @uow = uow
          @coupons = coupons
          @clock = clock
        end

        def call(actor, status: nil, search: nil, sort: "code", limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          status = Support.status!(status, P::COUPON_STATUSES)
          raise Domain::ValidationError.field("ordenacao", "inválida") unless SORTS.include?(sort.to_s)

          text = Support.search!(search)
          @uow.run(actor, "coupons.read") do |tx, _current|
            rows, total = @coupons.search(tx, status: status, search: text, sort: sort.to_s, limit: lim, offset: off, now: @clock.now)
            Page.new(items: rows.map { |coupon, state| { coupon: coupon, status: state } }, limit: lim, offset: off, total: total)
          end
        end
      end

      class GetCoupon
        def initialize(uow:, coupons:, audit_log:, clock:)
          @uow = uow
          @coupons = coupons
          @audit_log = audit_log
          @clock = clock
        end

        def call(actor, reference)
          @uow.run(actor, "coupons.read") do |tx, _current|
            now = @clock.now
            coupon = Support.coupon(@coupons, tx, reference, now: now)
            { coupon: coupon, status: coupon.status(now), created_by_name: @coupons.actor_name(tx, coupon.created_by),
              deletable: DeleteCoupon.deletable?(@coupons, tx, coupon), history: @audit_log.for_resource(tx, "coupon", coupon.id) }
          end
        end
      end

      # Usos do cupom, com o estado derivado da reserva. O nome do cliente exige `customers.read` e os
      # dados da reserva, `reservations.read`; sem o escopo, os campos vêm nulos.
      class ListCouponRedemptions
        def initialize(uow:, coupons:, clock:)
          @uow = uow
          @coupons = coupons
          @clock = clock
        end

        def call(actor, reference, limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          @uow.run(actor, "coupons.read") do |tx, current|
            now = @clock.now
            coupon = Support.coupon(@coupons, tx, reference, now: now)
            refs = Authorizer.allowed?(current, "reservations.read")
            rows, total = @coupons.redemptions(tx, coupon.id, limit: lim, offset: off, now: now, reservation_refs: refs,
                                                              customer_names: Reservations::ListReservations.customer_names?(current))
            Page.new(items: rows.map { |row| item(row, refs, now) }, limit: lim, offset: off, total: total)
          end
        end

        private

        def item(row, refs, now)
          state = P::Redemptions.state(row["reservation_status"], row["hold_expires_at"], now)
          released = case state
                     when "released_cancelled" then row["cancelled_at"]
                     when "released_expired" then row["expired_at"] || row["hold_expires_at"]
                     end
          { id: row["id"], reservation_id: refs ? row["reservation_id"] : nil, reservation_code: row["reservation_code"],
            reservation_status: refs ? row["reservation_status"] : nil, customer_name: row["customer_name"],
            subtotal: Domain::Money.new(row["subtotal_cents"]), discount: Domain::Money.new(row["discount_cents"]),
            redeemed_at: row["redeemed_at"]&.getutc, state: state, released_at: released&.getutc }
        end
      end

      # Tarifas adicionais ------------------------------------------------------------------------------

      class CreateFee
        def initialize(uow:, fees:, audit:, clock:, ids:)
          @uow = uow
          @fees = fees
          @audit = audit
          @clock = clock
          @ids = ids
        end

        # attrs: code, name, description, default_amount (Money).
        def call(actor, attrs, tx: nil)
          Support.run(@uow, actor, "fees.write", tx) do |t, current|
            fee = P::Fee.build(id: @ids.uuid, organization_id: t.tenant_id!, code: attrs[:code], name: attrs[:name],
                               description: attrs[:description], default_amount: attrs[:default_amount], created_by: current.audit_actor_id,
                               now: @clock.now)
            raise Domain::Conflict.new("já existe tarifa com o código #{fee.code} (inclusive desativada)", code: "fee_code_taken") if @fees.insert(t, fee).zero?

            @audit.record(t, current, "fee.created", "fee", fee.id,
                          "code" => fee.code, "name" => fee.name, "default_amount_cents" => fee.default_amount.cents)
            fee
          end
        end
      end

      class UpdateFee
        def initialize(uow:, fees:, audit:, clock:)
          @uow = uow
          @fees = fees
          @audit = audit
          @clock = clock
        end

        # attrs: chaves parciais :name, :description, :default_amount.
        def call(actor, reference, attrs, lock_version: nil, tx: nil)
          Support.run(@uow, actor, "fees.write", tx) do |t, current|
            fee = Support.fee(@fees, t, reference, lock: true)
            Support.stale!(fee, lock_version, "stale_fee", "a tarifa")
            revised = fee.revise(attrs, now: @clock.now)
            next Result.new(record: fee, changed: false) if revised.equal?(fee)

            if @fees.update(t, revised, fee.lock_version).zero?
              raise Domain::Conflict.new("a tarifa foi alterada por outra operação; revise os valores atuais", code: "stale_fee")
            end

            @audit.record(t, current, "fee.updated", "fee", fee.id, "changes" => fee.changes(revised))
            Result.new(record: revised, changed: true)
          end
        end
      end

      class SetFeeActive
        def initialize(uow:, fees:, audit:, clock:)
          @uow = uow
          @fees = fees
          @audit = audit
          @clock = clock
        end

        def call(actor, reference, active:, tx: nil)
          Support.run(@uow, actor, "fees.write", tx) do |t, current|
            fee = Support.fee(@fees, t, reference, lock: true)
            changed = fee.set_active(active, now: @clock.now)
            next Result.new(record: fee, changed: false) if changed.equal?(fee)

            @fees.update(t, changed, fee.lock_version)
            @audit.record(t, current, active ? "fee.reactivated" : "fee.deactivated", "fee", fee.id, "code" => fee.code)
            Result.new(record: changed, changed: true)
          end
        end
      end

      class ListFees
        SORTS = %w[name code -created_at].freeze

        def initialize(uow:, fees:)
          @uow = uow
          @fees = fees
        end

        def call(actor, status: nil, search: nil, sort: "name", limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          status = Support.status!(status, P::FEE_STATUSES)
          raise Domain::ValidationError.field("ordenacao", "inválida") unless SORTS.include?(sort.to_s)

          text = Support.search!(search)
          @uow.run(actor, "fees.read") do |tx, _current|
            rows, total = @fees.search(tx, status: status, search: text, sort: sort.to_s, limit: lim, offset: off)
            Page.new(items: rows, limit: lim, offset: off, total: total)
          end
        end
      end

      class GetFee
        def initialize(uow:, fees:, audit_log:)
          @uow = uow
          @fees = fees
          @audit_log = audit_log
        end

        def call(actor, reference)
          @uow.run(actor, "fees.read") do |tx, _current|
            fee = Support.fee(@fees, tx, reference)
            { fee: fee, created_by_name: @fees.actor_name(tx, fee.created_by), history: @audit_log.for_resource(tx, "fee", fee.id) }
          end
        end
      end

      # Condições negociadas ------------------------------------------------------------------------------

      class CreatePriceAgreement
        OVERLAP = "já existe condição vigente ou agendada para este cliente e escopo no período; " \
                  "encerre-a ou agende o encerramento antes"

        def initialize(uow:, agreements:, customers:, catalog:, audit:, clock:, ids:)
          @uow = uow
          @agreements = agreements
          @customers = customers
          @catalog = catalog
          @audit = audit
          @clock = clock
          @ids = ids
        end

        # attrs: product (UUID ou SKU; vazio = condição geral), discount_bps, valid_from, valid_until, notes.
        def call(actor, customer_id, attrs, tx: nil)
          Support.run(@uow, actor, "price_agreements.write", tx) do |t, current|
            now = @clock.now
            customer = @customers.find(t, Domain::Identifier.parse(customer_id, "cliente")) || raise(Domain::NotFound, "cliente")
            product = product!(t, attrs[:product])
            agreement = P::Agreement.build(id: @ids.uuid, organization_id: t.tenant_id!, customer_id: customer.id, product_id: product&.id,
                                           discount_bps: attrs[:discount_bps], valid_from: attrs[:valid_from], valid_until: attrs[:valid_until],
                                           notes: attrs[:notes], created_by: current.audit_actor_id, now: now)
            raise Domain::Conflict.new(OVERLAP, code: "price_agreement_overlap") if @agreements.overlapping?(t, agreement)

            insert!(t, agreement)
            @audit.record(t, current, "price_agreement.created", "price_agreement", agreement.id,
                          "customer_id" => customer.id, "product_id" => agreement.product_id, "discount_bps" => agreement.discount_bps,
                          "valid_from" => agreement.valid_from.iso8601, "valid_until" => agreement.valid_until&.iso8601)
            agreement
          end
        end

        private

        # Corrida entre duas criações: a exclusion constraint recusa a segunda no mesmo escopo.
        def insert!(tx, agreement)
          tx.savepoint { @agreements.insert(tx, agreement) }
        rescue AllocationConflict
          raise Domain::Conflict.new(OVERLAP, code: "price_agreement_overlap")
        end

        def product!(tx, reference)
          text = reference.to_s.strip
          return nil if text.empty?

          product = if Domain::Identifier.valid?(text.downcase)
                      @catalog.find_product(tx, text.downcase)
                    else
                      @catalog.find_product_by_sku(tx, text.upcase)
                    end
          raise Domain::NotFound, "produto" unless product
          raise Domain::ValidationError.field("produto", "produto inativo") unless product.active

          product
        end
      end

      # Encerramento único, imediato ou agendado. `customer_id`, quando informado, precisa ser o da
      # condição (rotas aninhadas no cliente).
      class EndPriceAgreement
        def initialize(uow:, agreements:, audit:, clock:, organizations: nil)
          @uow = uow
          @agreements = agreements
          @audit = audit
          @clock = clock
          @organizations = organizations
        end

        def call(actor, agreement_id, reason:, at: nil, customer_id: nil, tx: nil)
          Support.run(@uow, actor, "price_agreements.write", tx) do |t, current|
            now = @clock.now
            agreement = find!(t, agreement_id, customer_id)
            previous = agreement.status(now)
            zone = @organizations&.find(t, t.tenant_id!)&.time_zone
            ended = agreement.end_at(now: now, at: at, by: current.audit_actor_id, reason: reason, zone: zone)
            @agreements.end_agreement(t, ended)
            @audit.record(t, current, "price_agreement.ended", "price_agreement", agreement.id,
                          "customer_id" => agreement.customer_id, "reason" => ended.end_reason, "ended_at" => ended.ended_at.iso8601,
                          "scheduled" => ended.ended_at > now, "previous_status" => previous)
            ended
          end
        end

        private

        def find!(tx, agreement_id, customer_id)
          missing = Domain::NotFound.new("condição negociada", feminine: true)
          raise missing unless Domain::Identifier.valid?(agreement_id.to_s.strip.downcase)

          agreement = @agreements.lock(tx, agreement_id.to_s.strip.downcase)
          raise missing unless agreement
          raise missing if customer_id && agreement.customer_id != customer_id.to_s.strip.downcase

          agreement
        end
      end

      class ListPriceAgreements
        def initialize(uow:, agreements:, clock:, customers: nil)
          @uow = uow
          @agreements = agreements
          @clock = clock
          @customers = customers
        end

        def call(actor, customer_id, limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          @uow.run(actor, "price_agreements.read") do |tx, current|
            now = @clock.now
            id = Domain::Identifier.parse(customer_id, "cliente")
            raise Domain::NotFound, "cliente" if @customers && @customers.find(tx, id).nil?

            products = Authorizer.allowed?(current, "catalog.read")
            rows, total = @agreements.for_customer(tx, id, limit: lim, offset: off, products: products, now: now)
            Page.new(items: rows.map { |row| item(row, products, now) }, limit: lim, offset: off, total: total)
          end
        end

        private

        # row: { agreement:, product_sku:, product_name:, created_by_name:, ended_by_name: }
        def item(row, products, now)
          agreement = row[:agreement]
          product = { id: agreement.product_id, sku: row[:product_sku], name: row[:product_name] } if products && agreement.product_id
          { agreement: agreement, status: agreement.status(now), product: product,
            created_by_name: row[:created_by_name], ended_by_name: row[:ended_by_name] }
        end
      end
    end
  end
end
