# frozen_string_literal: true

# Atalhos dos testes de condições comerciais (repositório, integração e concorrência): cadastro pelos
# casos de uso, pedidos de tarifa e leituras de verificação.
module CommercialTermsSupport
  Pricing = Locentra::Domain::Pricing

  def create_coupon(code, actor: @actor, kind: "percent", value: 1000, **attrs)
    uc(:create_coupon).call(actor, { code: code, kind: kind, value: value, **attrs })
  end

  def create_fee(code, name, cents, actor: @actor, **attrs)
    uc(:create_fee).call(actor, { code: code, name: name, default_amount: Locentra::Domain::Money.new(cents), **attrs })
  end

  def create_agreement(customer, bps, actor: @actor, **attrs)
    uc(:create_price_agreement).call(actor, customer.id, { discount_bps: bps, **attrs })
  end

  def catalog_fee(fee, cents = nil)
    Pricing::FeeRequest.catalog(fee_id: fee.id, amount: cents && Locentra::Domain::Money.new(cents))
  end

  def custom_fee(description, cents) = Pricing::FeeRequest.custom(description: description, amount: Locentra::Domain::Money.new(cents))

  def coupon_data(reference, actor: @actor) = uc(:get_coupon).call(actor, reference)
  def usage(reference, actor: @actor) = coupon_data(reference, actor: actor)[:coupon].usage_text
  def redemptions_of(reference, actor: @actor) = uc(:list_coupon_redemptions).call(actor, reference).items
  def summary_of(reservation, actor: @actor) = uc(:get_reservation).call(actor, reservation.id)[:pricing][:summary]
  def status_of(reservation, actor: @actor) = uc(:get_reservation).call(actor, reservation.id)[:reservation].status

  # Transação com o papel de aplicação no contexto da organização (RLS e privilégios reais).
  def tenant_tx(org = @org, &) = @system.transactor.call(tenant_id: org[:organization_id], &)

  def audit_events(action, org: @org)
    owner_query("SELECT actor_type, actor_id, resource_type, resource_id, request_id, details FROM audit_events WHERE action = $1 ORDER BY occurred_at, id",
                [action], tenant: org[:organization_id]).map { |row| row.merge("details" => JSON.parse(row["details"])) }
  end

  def error_fields(&)
    assert_raises(Locentra::Domain::ValidationError, &).errors
  end

  def conflict_code(&)
    assert_raises(Locentra::Domain::Conflict, &).code
  end
end
