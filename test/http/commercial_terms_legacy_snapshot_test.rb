# frozen_string_literal: true

require_relative "portal_http_helper"
require_relative "../support/commercial_terms_support"

# Reservas registradas na versão 1.0.0 guardam o cupom só em `coupon_code`, sem `coupon` nem
# `agreements` no resumo e sem `negotiated_agreement_id` nos itens. As telas da equipe e do portal, a
# API, os termos do contrato e o PDF continuam exibindo esses snapshots depois da atualização.
class CommercialTermsLegacySnapshotTest < PortalHttpTest
  include CommercialTermsSupport

  def pdf_text(contract)
    document = uc(:get_contract).call(@actor, contract.id)[:documents].first
    bytes = uc(:download_attachment).call(@actor, document["attachment_id"]).last
    bytes.b.scan(/<([0-9a-f]+)> Tj/).map { |(hex)| [hex].pack("H*").force_encoding("Windows-1252").encode("UTF-8") }.join(" ")
  end

  # Copia uma reserva atual com o resumo e os itens no formato da 1.0.0.
  def legacy_copy(reservation)
    id = SecureRandom.uuid
    owner_query(<<~SQL, [id, reservation.id])
      INSERT INTO reservations (id, organization_id, branch_id, customer_id, code, status, source, starts_at, ends_at, pricing, total_cents,
                                deposit_cents, created_by, confirmed_at, created_at, updated_at)
      SELECT $1, organization_id, branch_id, customer_id, 'R-LEGADA', status, source, starts_at + interval '10 days', ends_at + interval '10 days',
             pricing - 'coupon' - 'agreements', total_cents, deposit_cents, created_by, confirmed_at, created_at, updated_at
        FROM reservations WHERE id = $2
    SQL
    owner_query(<<~SQL, [id, reservation.id])
      INSERT INTO reservation_items (id, organization_id, reservation_id, product_id, quantity, position, pricing, total_cents, created_at)
      SELECT gen_random_uuid(), organization_id, $1, product_id, quantity, position, pricing - 'negotiated_agreement_id', total_cents, created_at
        FROM reservation_items WHERE reservation_id = $2
    SQL
    id
  end

  def test_pages_api_terms_and_pdf_accept_a_1_0_0_snapshot
    portal_customer(@actor, @customer, email: "paula@cliente.test", name: "Paula Compras")
    create_agreement(@customer, 800)
    create_coupon("LEGADO10")
    legacy = legacy_copy(reserve(@actor, @customer, @branch, rental, [line(@camera, 1)], mode: "confirm", coupon_code: "LEGADO10"))
    stored = JSON.parse(owner_query("SELECT pricing::text AS p FROM reservations WHERE id = $1", [legacy]).first["p"])

    assert_equal ["LEGADO10", false, false], [stored["coupon_code"], stored.key?("coupon"), stored.key?("agreements")]
    contract = uc(:issue_contract).call(@actor, legacy)

    assert_equal "LEGADO10", contract.terms["pricing"]["coupon_code"]
    text = pdf_text(contract)

    assert_includes text, "Desconto por cupom LEGADO10: -R$ 13,80"
    assert_includes text, "condição negociada -8% (-R$ 12,00)"
    refute_includes text, "?"
    token = uc(:create_credential).call(@actor, name: "ERP", scopes: %w[reservations.read], expires_in_days: 30)["token"]
    get "/api/v1/reservations/#{legacy}", {}, { "HTTP_AUTHORIZATION" => "Bearer #{token}" }

    assert_equal [200, "LEGADO10", nil], [last_response.status, *JSON.parse(last_response.body)["pricing"].values_at("coupon_code", "coupon")]
    portal_login
    [get_ok("/portal/reservas/#{legacy}"), get_ok("/portal/contratos/#{contract.id}")].each do |page|
      assert_includes page, "<dt>Cupom LEGADO10</dt>"
      assert_includes page, "<dd>−R$ 13,80</dd>"
    end
    clear_cookies
    login("dona@alfa.test")
    staff = get_ok("/reservas/#{legacy}")

    assert_includes staff, "<dt>Cupom LEGADO10</dt>", "sem o identificador do cupom, sem ligação"
    assert_includes staff, "−8% (−R$ 12,00)"
    assert_includes get_ok("/contratos/#{contract.id}"), "<dt>Cupom LEGADO10</dt>"
  end
end
