# frozen_string_literal: true

module Locentra
  module Application
    # Orçamentos: versões imutáveis precificadas com o Pricer (sem consumir cupons), envio com
    # política de bloqueio explícita, aprovação da versão atual, rejeição, expiração e conversão
    # idempotente em reserva usando o snapshot de preços da versão aprovada.
    module Quotes
      Q = Domain::Quotes

      # Acesso ao orçamento respeitando o escopo do ator: clientes só enxergam os próprios
      # orçamentos; qualquer outro caso resulta em "não encontrado".
      module Scope
        module_function

        def lock!(quotes, tx, actor, quote_id)
          visible!(actor, quotes.lock(tx, Domain::Identifier.parse(quote_id)))
        end

        def find!(quotes, tx, actor, quote_id)
          visible!(actor, quotes.find(tx, Domain::Identifier.parse(quote_id)))
        end

        def visible!(actor, quote)
          raise Domain::NotFound, "orçamento" unless quote
          raise Domain::NotFound, "orçamento" if actor.customer? && quote.customer_id != actor.customer_id

          quote
        end

        def read_permission(actor) = actor.customer? ? "portal.access" : "quotes.read"
        def decision_permission(actor) = actor.customer? ? "portal.access" : "quotes.write"
      end

      # Monta e precifica o conteúdo de uma versão, sem gravar. Os preços vêm do catálogo vigente e
      # do Pricer com `redeem: false`: o orçamento não consome cupons nem altera disponibilidade.
      class VersionBuilder
        def initialize(organizations:, allocator:, pricer:, ids:)
          @organizations = organizations
          @allocator = allocator
          @pricer = pricer
          @ids = ids
        end

        def build(tx, actor, quote_id:, number:, customer_id:, input:, org:, now:)
          period = input.fetch(:period)
          Domain::Reservations::Rules.validate_start!(period, now)
          lines = Domain::Reservations::Rules.normalize_lines(input.fetch(:lines))
          branch_id = active_branch!(tx, input.fetch(:branch_id))
          valid_until = Q::Rules.valid_until!(input[:valid_until], period: period, now: now)
          discount = discount_bps(input.fetch(:manual_discount_bps, 0))
          priced, summary = @pricer.price(tx, products: active_products!(tx, lines), lines: lines, period: period, zone: org.time_zone,
                                              customer_id: customer_id, now: now, manual_discount_bps: discount,
                                              discount_limit_bps: actor.user? ? Domain::Identity.discount_limit_bps(actor.role) : 0,
                                              redeem: false)
          Q::Version.new(id: @ids.uuid, quote_id: quote_id, number: number, branch_id: branch_id, period: period, valid_until: valid_until,
                         items: priced, pricing: summary, terms: Q::Rules.terms(input[:terms]), manual_discount_bps: discount,
                         deposit: Domain::Money.new(summary.fetch("deposit_cents")), total: Domain::Money.new(summary.fetch("total_cents")),
                         created_at: now)
        end

        private

        def discount_bps(value)
          Integer(value.to_s, 10)
        rescue ArgumentError
          raise Domain::ValidationError.field("desconto", "percentual inválido")
        end

        def active_branch!(tx, branch_id)
          id = Domain::Identifier.parse(branch_id, "filial")
          raise Domain::NotFound, "filial" unless @organizations.branch_active?(tx, id)

          id
        end

        def active_products!(tx, lines)
          products = @allocator.products_for(tx, lines.map(&:product_id))
          lines.each { |l| raise Domain::NotFound, "produto" unless products[l.product_id]&.fetch(:product)&.active }
          products
        end
      end

      # Libera o bloqueio temporário criado no envio quando o orçamento deixa de estar enviado
      # (nova versão, rejeição ou expiração). A decisão é tomada sobre a linha bloqueada (FOR UPDATE):
      # um bloqueio expirado pela varredura ou cancelado diretamente enquanto isso é mantido como está.
      class HoldRelease
        def initialize(reservations:, cancel:)
          @reservations = reservations
          @cancel = cancel
        end

        def call(tx, actor, quote, reason)
          return nil unless quote.hold_reservation_id

          hold = @reservations.lock(tx, quote.hold_reservation_id)
          return nil unless hold&.held?

          @cancel.call(actor, hold.id, reason: "#{reason} (orçamento #{quote.code})", tx: tx, via: :quote)
        end
      end

      # Expiração de um orçamento enviado cuja validade venceu: grava a situação, libera o bloqueio e
      # publica o evento. Usada pela varredura do worker e pela tentativa de aprovação.
      class Expirer
        def initialize(quotes:, hold_release:, audit:, events:)
          @quotes = quotes
          @hold_release = hold_release
          @audit = audit
          @events = events
        end

        def call(tx, actor, quote, now, trigger)
          expired = quote.expire(now)
          @quotes.update(tx, expired, now)
          @hold_release.call(tx, actor, quote, "Orçamento expirado")
          @audit.record(tx, actor, "quote.expired", "quote", quote.id, "code" => quote.code, "version" => quote.current_version,
                                                                       "trigger" => trigger)
          @events.publish(tx, "quote.expired", "quote", quote.id, "code" => quote.code)
          expired
        end
      end

      class CreateQuote
        def initialize(uow:, quotes:, customers:, organizations:, builder:, audit:, clock:, ids:)
          @uow = uow
          @quotes = quotes
          @customers = customers
          @organizations = organizations
          @builder = builder
          @audit = audit
          @clock = clock
          @ids = ids
        end

        # input: customer_id, branch_id, period, lines, valid_until, terms, manual_discount_bps,
        # hold_policy ('none' | 'hold_on_send'), hold_minutes.
        def call(actor, input)
          @uow.run(actor, "quotes.write") do |tx, current|
            now = @clock.now
            customer = active_customer!(tx, input.fetch(:customer_id))
            org = @organizations.find(tx, tx.tenant_id!)
            policy = Q::Rules.hold_policy!(input[:hold_policy])
            hold_minutes = Q::Rules.hold_minutes!(policy, input[:hold_minutes] || org.hold_minutes)
            id = @ids.uuid
            version = @builder.build(tx, current, quote_id: id, number: 1, customer_id: customer.id, input: input, org: org, now: now)
            quote = Q::Quote.draft(id: id, organization_id: tx.tenant_id!, customer_id: customer.id, branch_id: version.branch_id,
                                   hold_policy: policy, hold_minutes: hold_minutes)
            @quotes.insert(tx, quote, current.audit_actor_id, now)
            @quotes.insert_version(tx, version, current.audit_actor_id)
            quote = quote.with(code: @organizations.next_code(tx, "quote", "Q"))
            @quotes.assign_code(tx, quote.id, quote.code)
            @audit.record(tx, current, "quote.created", "quote", quote.id, "code" => quote.code, "version" => 1,
                                                                           "total_cents" => version.total.cents, "hold_policy" => policy)
            quote
          end
        end

        private

        def active_customer!(tx, customer_id)
          customer = @customers.find(tx, Domain::Identifier.parse(customer_id, "cliente")) || raise(Domain::NotFound, "cliente")
          raise Domain::ValidationError.field("cliente", "cliente bloqueado ou inativo") unless customer.status == "active"

          customer
        end
      end

      # Nova versão: grava o novo conteúdo como versão imutável, volta o orçamento a rascunho
      # (exigindo novo envio) e libera o bloqueio temporário do envio anterior.
      class ReviseQuote
        def initialize(uow:, quotes:, customers:, organizations:, builder:, hold_release:, audit:, clock:)
          @uow = uow
          @quotes = quotes
          @customers = customers
          @organizations = organizations
          @builder = builder
          @hold_release = hold_release
          @audit = audit
          @clock = clock
        end

        def call(actor, quote_id, input)
          @uow.run(actor, "quotes.write") do |tx, current|
            now = @clock.now
            quote = Scope.lock!(@quotes, tx, current, quote_id)
            raise Domain::InvalidTransition.new("orçamento", quote.status, "nova versão") unless quote.revisable?

            customer = @customers.find(tx, quote.customer_id)
            raise Domain::ValidationError.field("cliente", "cliente bloqueado ou inativo") unless customer&.status == "active"

            org = @organizations.find(tx, tx.tenant_id!)
            policy = Q::Rules.hold_policy!(input[:hold_policy] || quote.hold_policy)
            hold_minutes = Q::Rules.hold_minutes!(policy, input[:hold_minutes] || quote.hold_minutes || org.hold_minutes)
            previous = @quotes.find_version(tx, quote.id, quote.current_version)
            version = @builder.build(tx, current, quote_id: quote.id, number: quote.current_version + 1, customer_id: quote.customer_id,
                                                  input: input, org: org, now: now)
            ensure_changed!(quote, previous, version, policy, hold_minutes)
            revised = quote.revise(branch_id: version.branch_id, hold_policy: policy, hold_minutes: hold_minutes)
            @hold_release.call(tx, current, quote, "Nova versão do orçamento")
            @quotes.insert_version(tx, version, current.audit_actor_id)
            @quotes.update(tx, revised, now)
            @audit.record(tx, current, "quote.revised", "quote", quote.id,
                          "code" => quote.code, "from_version" => previous.number, "to_version" => version.number,
                          "previous_status" => quote.status, "total_cents" => version.total.cents)
            revised
          end
        end

        private

        def ensure_changed!(quote, previous, version, policy, hold_minutes)
          unchanged = version.fingerprint == previous.fingerprint && policy == quote.hold_policy && hold_minutes == quote.hold_minutes
          raise Domain::ValidationError.field("base", "nenhuma alteração em relação à versão #{previous.number}") if unchanged
        end
      end

      # Envio da versão atual. Com `hold_on_send`, cria na mesma transação uma reserva em bloqueio
      # temporário (até 1440 minutos) com o snapshot de preços da versão, vinculada ao orçamento.
      # Com `none`, o envio não garante disponibilidade.
      class SendQuote
        def initialize(uow:, quotes:, create_reservation:, audit:, events:, clock:)
          @uow = uow
          @quotes = quotes
          @create_reservation = create_reservation
          @audit = audit
          @events = events
          @clock = clock
        end

        def call(actor, quote_id)
          @uow.run(actor, "quotes.write") do |tx, current|
            now = @clock.now
            quote = Scope.lock!(@quotes, tx, current, quote_id)
            version = @quotes.find_version(tx, quote.id, quote.current_version)
            sent = quote.send_version(version, now)
            hold = create_hold(tx, current, sent, version) if sent.hold_on_send?
            sent = sent.with_hold(hold.id) if hold
            @quotes.update(tx, sent, now)
            @audit.record(tx, current, "quote.sent", "quote", quote.id, "code" => quote.code, "version" => version.number,
                                                                        "hold_policy" => quote.hold_policy, "hold_reservation" => hold&.code)
            @events.publish(tx, "quote.sent", "quote", quote.id, "code" => quote.code, "version" => version.number,
                                                                 "total_cents" => version.total.cents, "valid_until" => version.valid_until.iso8601,
                                                                 "hold_policy" => quote.hold_policy)
            sent
          end
        end

        private

        def create_hold(tx, current, quote, version)
          Authorizer.authorize!(current, "reservations.write")
          @create_reservation.call(current, {
                                     customer_id: quote.customer_id, branch_id: version.branch_id, period: version.period, lines: version.lines,
                                     mode: "hold", hold_minutes: quote.hold_minutes, source: "quote",
                                     notes: "Bloqueio temporário do orçamento #{quote.code} (versão #{version.number})",
                                     pricing_snapshot: { items: version.items, summary: version.pricing }
                                   }, tx: tx)
        rescue Domain::Unavailable => e
          raise Domain::Unavailable.new(e.shortages, "Sem disponibilidade para o bloqueio temporário do orçamento; ajuste a versão ou envie sem bloqueio")
        end
      end

      # Aprovação da versão atual por alguém da equipe (em nome do cliente) ou pelo próprio cliente
      # (ator `customer`, restrito ao próprio cadastro). Orçamento vencido é marcado como expirado.
      class ApproveQuote
        def initialize(uow:, quotes:, expirer:, audit:, events:, clock:)
          @uow = uow
          @quotes = quotes
          @expirer = expirer
          @audit = audit
          @events = events
          @clock = clock
        end

        def call(actor, quote_id, version:, approver_name:)
          number = parse_version(version)
          result = @uow.run(actor, Scope.decision_permission(actor)) do |tx, current|
            now = @clock.now
            quote = Scope.lock!(@quotes, tx, current, quote_id)
            current_version = @quotes.find_version(tx, quote.id, quote.current_version)
            if quote.status == "sent" && current_version.expired?(now)
              @expirer.call(tx, current, quote, now, "approval_attempt")
              next :expired
            end

            approve(tx, current, quote, number, current_version, approver_name, now)
          end
          raise Domain::Conflict.new("Orçamento expirado: crie uma nova versão com nova validade", code: "quote_expired") if result == :expired

          result
        end

        private

        def parse_version(value)
          Integer(value.to_s, 10)
        rescue ArgumentError
          raise Domain::ValidationError.field("versao", "informe a versão aprovada")
        end

        def approve(tx, current, quote, number, version, approver_name, now)
          approver = Q::Approver.build(type: current.customer? ? "customer" : "staff", user_id: current.user_id, name: approver_name,
                                       ip: current.ip)
          approved = quote.approve(number, version: version, approver: approver, now: now)
          @quotes.update(tx, approved, now)
          @audit.record(tx, current, "quote.approved", "quote", quote.id,
                        "code" => quote.code, "version" => number, "approved_by_type" => approver.type, "approved_by_name" => approver.name,
                        "ip" => approver.ip)
          @events.publish(tx, "quote.approved", "quote", quote.id, "code" => quote.code, "version" => number, "total_cents" => version.total.cents)
          approved
        end
      end

      class RejectQuote
        def initialize(uow:, quotes:, hold_release:, audit:, events:, clock:)
          @uow = uow
          @quotes = quotes
          @hold_release = hold_release
          @audit = audit
          @events = events
          @clock = clock
        end

        def call(actor, quote_id, reason:)
          @uow.run(actor, Scope.decision_permission(actor)) do |tx, current|
            now = @clock.now
            quote = Scope.lock!(@quotes, tx, current, quote_id)
            rejected = quote.reject(reason, now)
            @quotes.update(tx, rejected, now)
            @hold_release.call(tx, current, quote, "Orçamento rejeitado")
            @audit.record(tx, current, "quote.rejected", "quote", quote.id, "code" => quote.code, "version" => quote.current_version,
                                                                            "reason" => rejected.rejection_reason)
            @events.publish(tx, "quote.rejected", "quote", quote.id, "code" => quote.code, "version" => quote.current_version)
            rejected
          end
        end
      end

      # Varredura de orçamentos enviados com validade vencida (worker). Orçamentos em uso por outra
      # transação são ignorados nesta execução (SKIP LOCKED).
      class ExpireQuotes
        def initialize(uow:, quotes:, expirer:, clock:)
          @uow = uow
          @quotes = quotes
          @expirer = expirer
          @clock = clock
        end

        def call(actor, limit: 200)
          @uow.run(actor) do |tx, current|
            now = @clock.now
            @quotes.lock_expired_sent(tx, now, limit).map { |quote| @expirer.call(tx, current, quote, now, "sweeper").id }
          end
        end
      end

      # Conversão idempotente do orçamento aprovado em reserva confirmada.
      #
      # O orçamento é bloqueado (FOR UPDATE): conversões concorrentes são serializadas e a segunda
      # encontra a reserva já vinculada. O índice único parcial em reservations (organization_id,
      # quote_id) garante, no banco, no máximo uma reserva por orçamento. A reserva usa o snapshot de
      # preços da versão aprovada, nunca o catálogo atual. Com bloqueio temporário vigente, a própria
      # reserva bloqueada é confirmada, desde que ainda corresponda à versão aprovada.
      class ConvertQuote
        Result = Data.define(:quote, :reservation, :created)
        DUPLICATE_CODE = "duplicate:reservations_quote_key"

        def initialize(uow:, quotes:, reservations:, create_reservation:, confirm_reservation:, audit:, events:, clock:)
          @uow = uow
          @quotes = quotes
          @reservations = reservations
          @create_reservation = create_reservation
          @confirm_reservation = confirm_reservation
          @audit = audit
          @events = events
          @clock = clock
        end

        def call(actor, quote_id)
          @uow.run(actor, "quotes.write") do |tx, current|
            Authorizer.authorize!(current, "reservations.write")
            quote = Scope.lock!(@quotes, tx, current, quote_id)
            existing = quote.reservation_id ? @reservations.find(tx, quote.reservation_id) : @reservations.find_by_quote(tx, quote.id)
            next Result.new(quote: quote, reservation: existing, created: false) if existing && quote.status == "converted"

            convert(tx, current, quote, existing)
          end
        end

        private

        def convert(tx, current, quote, existing)
          now = @clock.now
          raise Domain::InvalidTransition.new("orçamento", quote.status, "converted") unless quote.status == "approved"

          version = @quotes.find_version(tx, quote.id, quote.approved_version)
          reservation = existing || from_hold(tx, current, quote, version, now)
          unless reservation
            reservation, created = create(tx, current, quote, version)
            # Outra transação converteu primeiro (detectado pelo índice único): devolve a mesma reserva.
            return Result.new(quote: @quotes.find(tx, quote.id), reservation: reservation, created: false) unless created
          end

          @reservations.link_quote(tx, reservation.id, quote.id) unless reservation.quote_id == quote.id
          converted = quote.convert(reservation.id, now)
          @quotes.update(tx, converted, now)
          @audit.record(tx, current, "quote.converted", "quote", quote.id, "code" => quote.code, "version" => version.number,
                                                                           "reservation_id" => reservation.id, "reservation_code" => reservation.code,
                                                                           "from_hold" => reservation.id == quote.hold_reservation_id)
          @events.publish(tx, "quote.converted", "quote", quote.id, "code" => quote.code, "reservation_id" => reservation.id)
          Result.new(quote: converted, reservation: @reservations.find(tx, reservation.id), created: true)
        end

        # Bloqueio criado no envio, decidido sobre a linha bloqueada (FOR UPDATE): vigente, é confirmado
        # com revalidação; expirado ou cancelado (inclusive por outra transação concluída enquanto
        # esta aguardava o lock), uma nova reserva é criada a partir do snapshot. Se venceu no instante
        # da confirmação, a tentativa é desfeita (savepoint).
        def from_hold(tx, current, quote, version, now)
          return nil unless quote.hold_reservation_id

          hold = @reservations.lock(tx, quote.hold_reservation_id)
          return nil unless hold&.hold_valid?(now)

          ensure_hold_matches!(tx, quote, hold, version)
          tx.savepoint { @confirm_reservation.call(current, hold.id, tx: tx, via: :quote) }
        rescue Domain::HoldExpired
          nil
        rescue Domain::Unavailable => e
          raise Domain::Unavailable.new(e.shortages, "Sem disponibilidade para confirmar o bloqueio do orçamento #{quote.code}")
        end

        # A reserva de bloqueio não é alterada diretamente (ChangeGuard); esta verificação impede que
        # um bloqueio divergente da versão aprovada seja confirmado com os preços dessa versão.
        def ensure_hold_matches!(tx, quote, hold, version)
          items = @reservations.items(tx, hold.id).map { |i| [i["product_id"], i["quantity"]] }.sort
          expected = version.lines.map { |l| [l.product_id, l.quantity] }.sort
          return if hold.period == version.period && items == expected && hold.total == version.total

          raise Domain::Conflict.new("O bloqueio #{hold.code} não corresponde à versão #{version.number} aprovada do orçamento #{quote.code} " \
                                     "(período, itens ou valor): cancele a reserva de bloqueio e converta novamente",
                                     code: "quote_hold_mismatch")
        end

        # Retorna [reserva, criada?]. A criação ocorre sob savepoint: se o índice único acusar outra
        # reserva para o orçamento, a tentativa é desfeita e a reserva existente é devolvida.
        def create(tx, current, quote, version)
          reservation = tx.savepoint do
            @create_reservation.call(current, {
                                       customer_id: quote.customer_id, branch_id: version.branch_id, period: version.period, lines: version.lines,
                                       mode: "confirm", source: "quote", quote_id: quote.id,
                                       notes: "Convertida do orçamento #{quote.code} (versão #{version.number})",
                                       pricing_snapshot: { items: version.items,
                                                           summary: version.pricing.merge("quote_code" => quote.code, "quote_version" => version.number) }
                                     }, tx: tx)
          end
          [reservation, true]
        rescue Domain::Unavailable => e
          reason = quote.hold_on_send? ? "o bloqueio temporário do envio não está mais vigente" : "o orçamento enviado não garantia disponibilidade"
          raise Domain::Unavailable.new(e.shortages, "Sem disponibilidade para converter o orçamento #{quote.code}: #{reason}")
        rescue Domain::Conflict => e
          raise unless e.code == DUPLICATE_CODE

          [@reservations.find_by_quote(tx, quote.id) || raise(e), false]
        end
      end

      class ListQuotes
        SORTS = %w[-created_at created_at code].freeze

        def initialize(uow:, quotes:)
          @uow = uow
          @quotes = quotes
        end

        def call(actor, status: nil, customer_id: nil, search: nil, sort: "-created_at", limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          raise Domain::ValidationError.field("ordenacao", "inválida") unless SORTS.include?(sort)
          raise Domain::ValidationError.field("situacao", "inválida") if status && !Q::STATUSES.key?(status)

          @uow.run(actor, Scope.read_permission(actor)) do |tx, current|
            customer = current.customer? ? current.customer_id : (customer_id && Domain::Identifier.parse(customer_id, "cliente"))
            items, total = @quotes.search(tx, status: status, customer_id: customer, search: search.to_s.strip[0, 40], sort: sort,
                                              limit: lim, offset: off)
            Page.new(items: items, limit: lim, offset: off, total: total)
          end
        end
      end

      class GetQuote
        def initialize(uow:, quotes:, customers:, reservations:)
          @uow = uow
          @quotes = quotes
          @customers = customers
          @reservations = reservations
        end

        def call(actor, quote_id)
          @uow.run(actor, Scope.read_permission(actor)) do |tx, current|
            quote = Scope.find!(@quotes, tx, current, quote_id)
            versions = @quotes.versions(tx, quote.id)
            { quote: quote, versions: versions, current: versions.find { |v| v.number == quote.current_version },
              customer: @customers.find(tx, quote.customer_id),
              hold: quote.hold_reservation_id && @reservations.find(tx, quote.hold_reservation_id),
              reservation: quote.reservation_id && @reservations.find(tx, quote.reservation_id) }
          end
        end
      end
    end
  end
end
