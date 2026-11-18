# frozen_string_literal: true

module Locentra
  module Application
    # Contratos de locação emitidos a partir de reservas confirmadas: termos congelados, PDF
    # versionado (anexo com retenção), aceite eletrônico simples, aditivos de extensão compostos com
    # ExtendReservation e cancelamento com a política de cancelamento do contrato.
    module Contracts
      C = Domain::Contracts

      module Scope
        module_function

        def lock!(contracts, tx, actor, contract_id)
          visible!(actor, contracts.lock(tx, Domain::Identifier.parse(contract_id)))
        end

        def find!(contracts, tx, actor, contract_id)
          visible!(actor, contracts.find(tx, Domain::Identifier.parse(contract_id)))
        end

        def visible!(actor, contract)
          raise Domain::NotFound, "contrato" unless contract
          raise Domain::NotFound, "contrato" if actor.customer? && contract.customer_id != actor.customer_id

          contract
        end

        def read_permission(actor) = actor.customer? ? "portal.access" : "contracts.read"

        def total_with_amendments(contract, amendments)
          contract.contracted_total + Domain::Money.new(amendments.sum { |a| a.fetch("amount_delta_cents") })
        end

        def cancellation_preview(contract, amendments, now)
          C::Cancellation.calculate(policy: contract.cancellation_policy, total: total_with_amendments(contract, amendments),
                                    starts_at: contract.starts_at, now: now)
        end
      end

      # Gera uma versão do documento do contrato (PDF) a partir de dados reais e grava como anexo
      # (owner_type 'contract', retenção de cerca de cinco anos), registrando versão e SHA-256.
      class DocumentGenerator
        def initialize(contracts:, organizations:, renderer:, upload:, ids:)
          @contracts = contracts
          @organizations = organizations
          @renderer = renderer
          @upload = upload
          @ids = ids
        end

        def generate(tx, actor, contract, version:, reason:, amendments:, period:, now:)
          zone = @organizations.find(tx, tx.tenant_id!).time_zone
          snapshot = C::Terms.document_snapshot(contract: contract, version: version, reason: reason, amendments: amendments,
                                                current_period: period, zone: zone, now: now)
          bytes = @renderer.render(snapshot)
          attachment = @upload.call(actor, owner_type: "contract", owner_id: contract.id, filename: "contrato-#{contract.code}-v#{version}.pdf",
                                           bytes: bytes, retain_days: C::RETENTION_DAYS, tx: tx)
          document = { "id" => @ids.uuid, "contract_id" => contract.id, "version" => version, "reason" => reason,
                       "attachment_id" => attachment["id"], "sha256" => attachment["sha256"], "data_snapshot" => snapshot,
                       "generated_by" => actor.audit_actor_id, "generated_at" => now }
          @contracts.insert_document(tx, document)
          document
        end
      end

      # Emissão idempotente: a reserva é bloqueada e, se já houver contrato, ele é devolvido.
      class IssueContract
        def initialize(uow:, contracts:, reservations:, customers:, organizations:, quotes:, documents:, audit:, events:, clock:, ids:)
          @uow = uow
          @contracts = contracts
          @reservations = reservations
          @customers = customers
          @organizations = organizations
          @quotes = quotes
          @documents = documents
          @audit = audit
          @events = events
          @clock = clock
          @ids = ids
        end

        def call(actor, reservation_id, conditions: nil)
          @uow.run(actor, "contracts.write") do |tx, current|
            now = @clock.now
            reservation = @reservations.lock(tx, Domain::Identifier.parse(reservation_id, "reserva")) || raise(Domain::NotFound, "reserva")
            existing = @contracts.find_by_reservation(tx, reservation.id)
            next existing if existing

            issue(tx, current, reservation, conditions, now)
          end
        end

        private

        def issue(tx, current, reservation, conditions, now)
          org = @organizations.find(tx, tx.tenant_id!)
          terms = build_terms(tx, org, reservation, conditions, now)
          contract = C::Contract.issue(id: @ids.uuid, organization_id: tx.tenant_id!, reservation: reservation, terms: terms, now: now)
          @contracts.insert(tx, contract, current.audit_actor_id, now)
          # O código definitivo é atribuído no fim da transação, antes da geração do documento que o exibe.
          contract = contract.with(code: @organizations.next_code(tx, "contract", "C"))
          @contracts.assign_code(tx, contract.id, contract.code)
          document = @documents.generate(tx, current, contract, version: 1, reason: "issue", amendments: [], period: reservation.period, now: now)
          @audit.record(tx, current, "contract.issued", "contract", contract.id,
                        "code" => contract.code, "reservation_code" => reservation.code, "document_version" => 1, "sha256" => document["sha256"])
          @events.publish(tx, "contract.issued", "contract", contract.id,
                          "code" => contract.code, "reservation_id" => reservation.id, "reservation_code" => reservation.code)
          contract
        end

        def build_terms(tx, org, reservation, conditions, now)
          customer = @customers.find(tx, reservation.customer_id)
          pricing = @reservations.pricing(tx, reservation.id)
          quote = reservation.quote_id && @quotes.find(tx, reservation.quote_id)
          quote_version = quote && @quotes.find_version(tx, quote.id, quote.approved_version)
          C::Terms.build(
            organization: { "name" => org.name, "legal_document" => @contracts.organization_document(tx), "timezone" => org.timezone },
            customer: customer, address: @customers.addresses(tx, customer.id).first,
            branch: @organizations.branches(tx).find { |b| b.id == reservation.branch_id }, reservation: reservation,
            items: @reservations.items(tx, reservation.id), pricing: pricing[:summary],
            adjustments_cents: pricing[:adjustments].sum { |a| a["amount_cents"] }, policy: org.cancellation_policy,
            conditions: Domain::Organizations::Text.optional(conditions, max: 5000) || quote_version&.terms,
            quote: quote && { "id" => quote.id, "code" => quote.code, "version" => quote.approved_version }, zone: org.time_zone, now: now
          )
        end
      end

      # Registro do aceite eletrônico simples da versão atual do documento, pela equipe (presencial)
      # ou pelo próprio cliente (ator `customer`). O primeiro aceite torna o contrato vigente.
      class AcceptContract
        def initialize(uow:, contracts:, audit:, events:, clock:)
          @uow = uow
          @contracts = contracts
          @audit = audit
          @events = events
          @clock = clock
        end

        def call(actor, contract_id, name:, document:, user_agent: nil, confirmed: false)
          raise Domain::ValidationError.field("declaracao", "confirme a declaração de aceite") unless confirmed

          @uow.run(actor, actor.customer? ? "portal.access" : "contracts.write") do |tx, current|
            now = @clock.now
            contract = Scope.lock!(@contracts, tx, current, contract_id)
            raise Domain::InvalidTransition.new("contrato", contract.status, "aceite") unless contract.open?

            doc = @contracts.lock_document(tx, contract.id, contract.current_document_version) || raise(Domain::NotFound, "documento")
            raise Domain::Conflict.new("A versão #{doc["version"]} do documento já possui aceite registrado", code: "already_accepted") if doc["accepted_at"]

            acceptance = C::Acceptance.build(name: name, document: document, ip: current.ip, user_agent: user_agent,
                                             via: current.customer? ? "portal" : "staff", user_id: current.user_id, now: now)
            @contracts.record_acceptance(tx, doc["id"], acceptance)
            accepted = contract.accept(now)
            @contracts.update(tx, accepted, now) unless accepted.equal?(contract)
            @audit.record(tx, current, "contract.accepted", "contract", contract.id,
                          "code" => contract.code, "document_version" => doc["version"], "sha256" => doc["sha256"],
                          "accepted_by_name" => acceptance.name, "via" => acceptance.via, "ip" => acceptance.ip)
            @events.publish(tx, "contract.accepted", "contract", contract.id, "code" => contract.code, "document_version" => doc["version"])
            accepted
          end
        end
      end

      # Aditivo de extensão de prazo: compõe ExtendReservation na mesma transação (o ajuste de valor
      # é gravado em reservation_adjustments), registra o aditivo com a diferença e gera nova versão
      # do documento. Extensão que invade outra reserva desfaz tudo, sem aditivo.
      class AmendContract
        AMENDMENT_KEYS = %w[number kind description changes amount_delta_cents document_version].freeze

        def initialize(uow:, contracts:, reservations:, extend_reservation:, documents:, organizations:, audit:, events:, clock:, ids:)
          @uow = uow
          @contracts = contracts
          @reservations = reservations
          @extend_reservation = extend_reservation
          @documents = documents
          @organizations = organizations
          @audit = audit
          @events = events
          @clock = clock
          @ids = ids
        end

        def call(actor, contract_id, ends_at:, description: nil)
          @uow.run(actor, "contracts.write") do |tx, current|
            Authorizer.authorize!(current, "reservations.write")
            now = @clock.now
            contract = Scope.lock!(@contracts, tx, current, contract_id)
            raise Domain::InvalidTransition.new("contrato", contract.status, "aditivo") unless contract.amendable?

            before = @reservations.find(tx, contract.reservation_id)
            result = @extend_reservation.call(current, contract.reservation_id, ends_at: ends_at, tx: tx, via: :contract)
            amend(tx, current, contract, before, result, description, now)
          end
        end

        private

        def amend(tx, current, contract, before, result, description, now)
          zone = @organizations.find(tx, tx.tenant_id!).time_zone
          previous = @contracts.amendments(tx, contract.id).map { |row| row.slice(*AMENDMENT_KEYS) }
          version = contract.current_document_version + 1
          amendment = C::Terms.extension_amendment(number: previous.size + 1, from: before.period, to: result[:reservation].period,
                                                   delta: result[:adjustment], zone: zone, description: description, document_version: version)
          amended = contract.amend(version)
          document = @documents.generate(tx, current, amended, version: version, reason: "amendment", amendments: previous + [amendment],
                                                               period: result[:reservation].period, now: now)
          @contracts.insert_amendment(tx, amendment.merge("id" => @ids.uuid, "contract_id" => contract.id, "created_by" => current.audit_actor_id,
                                                          "created_at" => now))
          @contracts.update(tx, amended, now)
          @audit.record(tx, current, "contract.amended", "contract", contract.id,
                        "code" => contract.code, "number" => amendment["number"], "kind" => "extension",
                        "amount_delta_cents" => amendment["amount_delta_cents"], "document_version" => version, "sha256" => document["sha256"])
          @events.publish(tx, "contract.amended", "contract", contract.id, "code" => contract.code, "number" => amendment["number"],
                                                                           "amount_delta_cents" => amendment["amount_delta_cents"])
          { contract: amended, amendment: amendment, adjustment: result[:adjustment], document: document }
        end
      end

      # Prévia da multa de cancelamento no instante atual, com a política congelada no contrato.
      class PreviewCancellation
        def initialize(uow:, contracts:, clock:)
          @uow = uow
          @contracts = contracts
          @clock = clock
        end

        def call(actor, contract_id)
          @uow.run(actor, Scope.read_permission(actor)) do |tx, current|
            contract = Scope.find!(@contracts, tx, current, contract_id)
            Scope.cancellation_preview(contract, @contracts.amendments(tx, contract.id), @clock.now)
          end
        end
      end

      # Cancelamento com política explícita: multa calculada com CancellationPolicy sobre o total
      # contratado, gravada como ajuste 'cancellation_fee' (quando positiva), reserva cancelada na
      # mesma transação e contrato marcado como cancelado. Depois da retirada (reserva em andamento
      # ou concluída), o cancelamento é recusado antes de qualquer cálculo ou gravação.
      class CancelContract
        def initialize(uow:, contracts:, reservations:, cancel_reservation:, audit:, events:, clock:, ids:)
          @uow = uow
          @contracts = contracts
          @reservations = reservations
          @cancel_reservation = cancel_reservation
          @audit = audit
          @events = events
          @clock = clock
          @ids = ids
        end

        def call(actor, contract_id, reason:)
          @uow.run(actor, "contracts.write") do |tx, current|
            Authorizer.authorize!(current, "reservations.cancel")
            now = @clock.now
            contract = Scope.lock!(@contracts, tx, current, contract_id)
            reservation = @reservations.lock(tx, contract.reservation_id)
            preview = Scope.cancellation_preview(contract, @contracts.amendments(tx, contract.id), now)
            cancelled = contract.cancel(now: now, reason: reason, fee: preview.fee, reservation: reservation)
            record_fee(tx, current, contract, preview, now) if preview.fee.positive?
            @cancel_reservation.call(current, contract.reservation_id,
                                     reason: "Contrato #{contract.code} cancelado: #{cancelled.cancellation_reason}"[0, 500], tx: tx,
                                     via: :contract)
            @contracts.update(tx, cancelled, now)
            @audit.record(tx, current, "contract.cancelled", "contract", contract.id,
                          preview.to_h.merge("code" => contract.code, "reason" => cancelled.cancellation_reason))
            @events.publish(tx, "contract.cancelled", "contract", contract.id, "code" => contract.code, "fee_cents" => preview.fee.cents)
            { contract: cancelled, preview: preview }
          end
        end

        private

        def record_fee(tx, current, contract, preview, now)
          @reservations.insert_adjustment(tx, "id" => @ids.uuid, "reservation_id" => contract.reservation_id, "reservation_item_id" => nil,
                                              "kind" => "cancellation_fee", "amount_cents" => preview.fee.cents,
                                              "details" => preview.to_h.merge("contract_id" => contract.id, "contract_code" => contract.code),
                                              "created_by" => current.audit_actor_id, "created_at" => now)
        end
      end

      # Encerramento após a conclusão da reserva (devolução registrada). Contrato sem aceite registrado
      # também é encerrado, com essa indicação na auditoria.
      class CloseContract
        def initialize(uow:, contracts:, reservations:, audit:, clock:)
          @uow = uow
          @contracts = contracts
          @reservations = reservations
          @audit = audit
          @clock = clock
        end

        def call(actor, contract_id)
          @uow.run(actor, "contracts.write") do |tx, current|
            now = @clock.now
            contract = Scope.lock!(@contracts, tx, current, contract_id)
            reservation = @reservations.find(tx, contract.reservation_id)
            unless reservation.status == "completed"
              raise Domain::Conflict.new("O contrato só é encerrado após a conclusão da reserva (situação atual: #{reservation.status_label})",
                                         code: "reservation_not_completed")
            end

            closed = contract.close(now)
            @contracts.update(tx, closed, now)
            @audit.record(tx, current, "contract.closed", "contract", contract.id, "code" => contract.code,
                                                                                   "accepted" => !contract.activated_at.nil?)
            closed
          end
        end
      end

      class ListContracts
        def initialize(uow:, contracts:)
          @uow = uow
          @contracts = contracts
        end

        def call(actor, status: nil, search: nil, limit: nil, offset: nil)
          lim, off = Page.params(limit: limit, offset: offset)
          raise Domain::ValidationError.field("situacao", "inválida") if status && !C::STATUSES.key?(status)

          @uow.run(actor, Scope.read_permission(actor)) do |tx, current|
            items, total = @contracts.search(tx, status: status, customer_id: current.customer? ? current.customer_id : nil,
                                                 search: search.to_s.strip[0, 40], limit: lim, offset: off)
            Page.new(items: items, limit: lim, offset: off, total: total)
          end
        end
      end

      class GetContract
        def initialize(uow:, contracts:, reservations:, clock:)
          @uow = uow
          @contracts = contracts
          @reservations = reservations
          @clock = clock
        end

        def call(actor, contract_id)
          @uow.run(actor, Scope.read_permission(actor)) do |tx, current|
            contract = Scope.find!(@contracts, tx, current, contract_id)
            amendments = @contracts.amendments(tx, contract.id)
            reservation = @reservations.find(tx, contract.reservation_id)
            { contract: contract, documents: @contracts.documents(tx, contract.id), amendments: amendments,
              reservation: reservation, current_total: Scope.total_with_amendments(contract, amendments),
              preview: contract.cancellable_with?(reservation) ? Scope.cancellation_preview(contract, amendments, @clock.now) : nil }
          end
        end
      end

      # Contrato e orçamento ligados a uma reserva (tela da reserva).
      class ReservationLinks
        def initialize(uow:, contracts:, quotes:)
          @uow = uow
          @contracts = contracts
          @quotes = quotes
        end

        def call(actor, reservation_id)
          @uow.run(actor, "reservations.read") do |tx, current|
            id = Domain::Identifier.parse(reservation_id, "reserva")
            contract = Authorizer.allowed?(current, "contracts.read") ? @contracts.find_by_reservation(tx, id) : nil
            quote = Authorizer.allowed?(current, "quotes.read") ? @quotes.find_by_reservation(tx, id) : nil
            { contract: contract, quote: quote }
          end
        end
      end
    end
  end
end
