# frozen_string_literal: true

module Locentra
  module Domain
    # Contratos de locação: termos congelados na emissão, documentos versionados, aceite eletrônico
    # simples, aditivos e cancelamento com política explícita.
    module Contracts
      STATUSES = {
        "issued" => "Emitido (aguardando aceite)",
        "active" => "Vigente",
        "closed" => "Encerrado",
        "cancelled" => "Cancelado"
      }.freeze

      # `issued -> closed`: locação concluída sem aceite registrado (o encerramento é auditado com essa
      # indicação). O cancelamento exige reserva ainda cancelável (antes da retirada).
      TRANSITIONS = {
        "issued" => %w[active closed cancelled],
        "active" => %w[closed cancelled],
        "closed" => [],
        "cancelled" => []
      }.freeze

      OPEN = %w[issued active].freeze
      ISSUABLE_RESERVATION_STATUSES = %w[confirmed in_progress].freeze
      AMENDMENT_KINDS = { "extension" => "Extensão de prazo" }.freeze
      DOCUMENT_REASONS = { "issue" => "Emissão", "amendment" => "Aditivo" }.freeze
      ACCEPTANCE_CHANNELS = { "staff" => "Registrado pela equipe", "portal" => "Portal do cliente" }.freeze

      # Retenção dos documentos gerados (aproximadamente cinco anos).
      RETENTION_DAYS = 1826

      ACCEPTANCE_NOTICE = "Este contrato é aceito por meio de aceite eletrônico simples, que registra nome, documento, endereço IP, " \
                          "navegador e instante informados no ato. O aceite eletrônico simples não equivale a assinatura digital " \
                          "certificada (ICP-Brasil)."
      ACCEPTANCE_STATEMENT = "Declaro que li o contrato de locação nesta versão e aceito suas condições por meio de aceite " \
                             "eletrônico simples, ciente de que este registro não equivale a assinatura digital certificada."

      GENERAL_CONDITIONS = [
        "Os equipamentos são entregues em condições de uso e devem ser devolvidos no mesmo estado, ressalvado o desgaste natural.",
        "Atrasos na devolução são cobrados conforme a tabela de preços vigente na contratação.",
        "Avarias, perdas e faltas constatadas na devolução são cobradas do locatário com base no custo de reposição.",
        "A caução prevista é devolvida após a conferência da devolução, deduzidos os valores devidos.",
        "Alterações de prazo são formalizadas por aditivo contratual com nova versão deste documento."
      ].freeze

      Contract = Data.define(:id, :organization_id, :code, :reservation_id, :customer_id, :quote_id, :status, :terms,
                             :current_document_version, :issued_at, :activated_at, :closed_at, :cancelled_at, :cancellation_reason,
                             :cancellation_fee_cents, :lock_version) do
        def self.issue(id:, organization_id:, reservation:, terms:, now:)
          unless ISSUABLE_RESERVATION_STATUSES.include?(reservation.status)
            raise Conflict.new("O contrato só pode ser emitido para reserva confirmada (situação atual: #{reservation.status_label})",
                               code: "reservation_not_confirmed")
          end

          new(id: id, organization_id: organization_id, code: "PEND-#{id}", reservation_id: reservation.id,
              customer_id: reservation.customer_id, quote_id: reservation.quote_id, status: "issued", terms: terms,
              current_document_version: 1, issued_at: now, activated_at: nil, closed_at: nil, cancelled_at: nil,
              cancellation_reason: nil, cancellation_fee_cents: nil, lock_version: 1)
        end

        def status_label = STATUSES.fetch(status)
        def open? = OPEN.include?(status)
        def amendable? = open?

        def transition(target)
          raise InvalidTransition.new("contrato", status, target) unless TRANSITIONS.fetch(status).include?(target)

          with(status: target, lock_version: lock_version + 1)
        end

        # Valor contratado na emissão (preço da reserva somado a ajustes anteriores à emissão).
        def contracted_total = Money.new(terms.fetch("contracted_total_cents"))

        def starts_at = Time.iso8601(terms.fetch("period").fetch("starts_at"))

        def cancellation_policy = terms.fetch("cancellation_policy")

        # O primeiro aceite registrado torna o contrato vigente; aceites de versões posteriores
        # (aditivos) mantêm a situação.
        def accept(now)
          raise InvalidTransition.new("contrato", status, "aceite") unless open?
          return self if status == "active"

          transition("active").with(activated_at: now)
        end

        # O aceite vale para a versão do documento exibida a quem aceita: se um aditivo gerou versão
        # nova depois disso, o aceite é recusado para que a versão vigente seja lida antes.
        def acceptable_version!(number)
          return number if number == current_document_version

          raise Conflict.new("A versão #{number} do documento não é mais a vigente (versão vigente: #{current_document_version}). " \
                             "Leia a versão vigente antes de registrar o aceite.", code: "stale_document_version")
        end

        def amend(document_version)
          raise InvalidTransition.new("contrato", status, "aditivo") unless amendable?
          raise InvariantViolation, "versão de documento fora de sequência" unless document_version == current_document_version + 1

          with(current_document_version: document_version, lock_version: lock_version + 1)
        end

        # Depois da retirada (reserva em andamento ou concluída), o contrato não é mais cancelado: é
        # encerrado após a devolução.
        def cancellable_with?(reservation) = TRANSITIONS.fetch(status).include?("cancelled") && reservation.cancellable?

        def cancel(now:, reason:, fee:, reservation:)
          cancelled = transition("cancelled")
          unless reservation.cancellable?
            raise Conflict.new("A reserva #{reservation.code} está #{reservation.status_label.downcase}: o contrato não pode mais ser " \
                               "cancelado e deve ser encerrado após a devolução", code: "contract_not_cancellable")
          end

          cancelled.with(cancelled_at: now, cancellation_reason: Organizations::Text.required(reason, "motivo", max: 500),
                         cancellation_fee_cents: fee.cents)
        end

        def close(now) = transition("closed").with(closed_at: now)
      end

      # Multa de cancelamento: faixa da política congelada no contrato aplicada ao total contratado
      # (valor da emissão somado às diferenças dos aditivos).
      module Cancellation
        Preview = Data.define(:base, :fee_bps, :fee, :hours_before, :policy) do
          def to_h
            { "base_cents" => base.cents, "fee_bps" => fee_bps, "fee_cents" => fee.cents, "hours_before" => hours_before }
          end
        end

        module_function

        def calculate(policy:, total:, starts_at:, now:)
          bps = Organizations::CancellationPolicy.fee_bps(policy, starts_at: starts_at, now: now)
          seconds = starts_at.to_i - now.to_i
          Preview.new(base: total, fee_bps: bps, fee: total.percent(bps), hours_before: seconds.negative? ? -(-seconds / 3600) : seconds / 3600,
                      policy: policy)
        end

        # Descrição legível das faixas, da maior para a menor antecedência.
        def describe(policy)
          tiers = policy.fetch("tiers").sort_by { |tier| -tier.fetch("min_hours_before") }
          tiers.each_with_index.map do |tier, index|
            min = tier.fetch("min_hours_before")
            upper = index.zero? ? nil : tiers[index - 1].fetch("min_hours_before")
            range = if upper.nil? then "#{min} h ou mais antes do início"
                    elsif min.zero? then "menos de #{upper} h antes do início (ou após o início)"
                    else "de #{min} h a menos de #{upper} h antes do início"
                    end
            "#{range}: multa de #{percent_label(tier.fetch("fee_bps"))} do valor contratado"
          end
        end

        def percent_label(bps) = Percent.label(bps)
      end

      # Aceite eletrônico simples: identificação declarada, IP, navegador e instante.
      Acceptance = Data.define(:name, :document, :ip, :user_agent, :via, :user_id, :accepted_at, :statement) do
        def self.build(name:, document:, ip:, user_agent:, via:, user_id:, now:)
          raise ValidationError.field("canal", "canal de aceite inválido") unless ACCEPTANCE_CHANNELS.key?(via)

          digits = Customers::Document.digits(document)
          valid = digits.length == 11 ? Customers::Document.valid_cpf?(digits) : Customers::Document.valid_cnpj?(digits)
          raise ValidationError.field("documento", "CPF ou CNPJ inválido") unless valid

          new(name: Organizations::Text.required(name, "nome", min: 3, max: 160), document: digits,
              ip: Organizations::Text.optional(ip, max: 64), user_agent: Organizations::Text.optional(user_agent, max: 500),
              via: via, user_id: user_id, accepted_at: now, statement: ACCEPTANCE_STATEMENT)
        end
      end

      # Montagem dos termos congelados na emissão e do snapshot de cada documento.
      module Terms
        module_function

        def period(period, zone)
          { "starts_at" => period.starts_at.iso8601, "ends_at" => period.ends_at.iso8601, "timezone" => zone.identifier,
            "starts_at_local" => zone.format_local(period.starts_at), "ends_at_local" => zone.format_local(period.ends_at) }
        end

        def build(organization:, customer:, address:, branch:, reservation:, items:, pricing:, adjustments_cents:, policy:, conditions:,
                  quote:, zone:, now:)
          {
            "organization" => organization, "customer" => customer_snapshot(customer, address),
            "branch" => branch && { "name" => branch.name, "code" => branch.code, "address" => branch.address },
            "reservation" => { "id" => reservation.id, "code" => reservation.code },
            "quote" => quote, "period" => period(reservation.period, zone), "items" => items.map { |item| item_snapshot(item) },
            "pricing" => pricing_snapshot(pricing), "total_cents" => reservation.total.cents, "adjustments_cents" => adjustments_cents,
            "contracted_total_cents" => reservation.total.cents + adjustments_cents, "deposit_cents" => reservation.deposit.cents,
            "cancellation_policy" => policy, "cancellation_terms" => Cancellation.describe(policy),
            "conditions" => conditions, "general_conditions" => GENERAL_CONDITIONS, "acceptance_notice" => ACCEPTANCE_NOTICE,
            "issued_at" => now.iso8601, "issued_at_local" => zone.format_local(now)
          }
        end

        def customer_snapshot(customer, address)
          { "id" => customer.id, "name" => customer.name, "kind" => customer.kind, "document" => customer.formatted_document,
            "email" => customer.email, "phone" => customer.phone, "address" => address && format_address(address) }
        end

        def format_address(address)
          street = [address.street, address.number].compact.join(", ")
          parts = [street, address.complement, address.district, "#{address.city}/#{address.state}"]
          parts << "CEP #{address.postal_code[0, 5]}-#{address.postal_code[5, 3]}" if address.postal_code
          parts.compact.join(" · ")
        end

        def item_snapshot(item)
          pricing = item.fetch("pricing")
          { "product_id" => item.fetch("product_id"), "sku" => item.fetch("sku"), "name" => item.fetch("name"),
            "quantity" => item.fetch("quantity"), "description" => pricing["description"], "unit_amount_cents" => pricing["unit_amount_cents"].to_i,
            "total_cents" => item.fetch("total_cents"), "deposit_unit_cents" => pricing["deposit_unit_cents"].to_i }
        end

        def pricing_snapshot(pricing)
          pricing.slice("subtotal_cents", "coupon_code", "coupon_discount_cents", "manual_discount_bps", "manual_discount_cents", "fees",
                        "fees_cents", "total_cents", "deposit_cents", "priced_at", "quote_code", "quote_version")
        end

        # Dados usados para gerar uma versão do documento: termos da emissão, aditivos até a versão
        # e período/valor vigentes.
        def document_snapshot(contract:, version:, reason:, amendments:, current_period:, zone:, now:)
          delta = amendments.sum { |a| a.fetch("amount_delta_cents") }
          {
            "contract_code" => contract.code, "document_version" => version, "reason" => reason,
            "generated_at" => now.iso8601, "generated_at_local" => zone.format_local(now), "terms" => contract.terms,
            "amendments" => amendments, "current_period" => period(current_period, zone),
            "current_total_cents" => contract.terms.fetch("contracted_total_cents") + delta, "acceptance_notice" => ACCEPTANCE_NOTICE
          }
        end

        def extension_amendment(number:, from:, to:, delta:, zone:, description:, document_version:)
          text = Organizations::Text.optional(description, max: 1000) ||
                 "Extensão da devolução de #{zone.format_local(from.ends_at)} para #{zone.format_local(to.ends_at)}"
          { "number" => number, "kind" => "extension", "description" => text,
            "changes" => { "from_end" => from.ends_at.iso8601, "to_end" => to.ends_at.iso8601,
                           "from_end_local" => zone.format_local(from.ends_at), "to_end_local" => zone.format_local(to.ends_at) },
            "amount_delta_cents" => delta.cents, "document_version" => document_version }
        end
      end
    end
  end
end
