# frozen_string_literal: true

require "digest"
require_relative "api_v1_helper"

# Contratos na API v1 (Rack::Lint): emissão 201/200, lista paginada com filtros, detalhe com prévia de
# cancelamento, PDF com cabeçalhos de download e integridade, aditivo, cancelamento com multa, escopos
# adicionais, idempotência, isolamento entre organizações e conformidade com o OpenAPI.
class ContractsApiTest < ApiV1TestCase
  SCOPES = %w[contracts.read contracts.write reservations.read reservations.write reservations.cancel].freeze

  def setup
    super
    @token = token(SCOPES)
  end

  def rental = period("2026-03-10T08:00:00Z", "2026-03-12T08:00:00Z")
  def reservation(window = rental, **) = confirmed([line(@camera, 1)], window, **)
  def issued(target = reservation) = uc(:issue_contract).call(@actor, target.id)

  def beta_contract = uc(:issue_contract).call(@beta[:actor], beta_reservation.id)

  def pdf_headers
    last_response.headers.slice("content-type", "content-disposition", "content-length", "cache-control", "x-content-type-options",
                                "content-security-policy", "repr-digest")
  end

  def test_issue_creates_then_returns_the_same_contract_with_location
    target = reservation
    body = post!(201, "/contracts", { "reservation_id" => target.id, "conditions" => "Entrega no local do evento." })

    assert_conforms body, "Contract"
    assert_equal "/api/v1/contracts/#{body["id"]}", location
    assert_equal ["issued", target.code, 1, 90_000], [body["status"], body["reservation_code"], body["current_document_version"],
                                                      body["contracted_total"]["amount_cents"]]
    assert_equal ["issue", "contrato-#{body["code"]}-v1.pdf", "/api/v1/contracts/#{body["id"]}/documents/1"],
                 body["documents"].first.values_at("reason", "filename", "download_path")
    again = post!(200, "/contracts", { "reservation_id" => target.id })

    assert_equal [body["id"], "/api/v1/contracts/#{body["id"]}"], [again["id"], location]
    assert_equal [1, 1], [count("SELECT count(*) FROM contracts"), audit_count("contract.issued")]
  end

  def test_issue_refuses_unconfirmed_reservations_missing_scope_and_invalid_input
    hold = reserve(@actor, @customer, @branch, rental, [line(@camera, 1)])
    post!(409, "/contracts", { "reservation_id" => hold.id })

    assert_error "reservation_not_confirmed"
    post!(403, "/contracts", { "reservation_id" => reservation.id }, token: token(%w[contracts.read reservations.read]))

    assert_error "forbidden"
    post!(422, "/contracts", { "reservation_id" => "R-000001" })

    assert_equal ["reserva"], fields.keys
    post!(422, "/contracts", { "reservation_id" => reservation(after_rental).id, "conditions" => 5 })

    assert_equal({ "condicoes" => ["informe um texto"] }, fields)
    post!(404, "/contracts", { "reservation_id" => beta_reservation.id })

    assert_error "not_found"
    assert_equal 0, count("SELECT count(*) FROM contracts")
  end

  def test_issue_is_idempotent
    target = reservation
    body = assert_idempotent("/contracts", { "reservation_id" => target.id }, 201, changed_body: { "reservation_id" => target.id, "conditions" => "Outra" })

    assert_equal ["/api/v1/contracts/#{body["id"]}", 1], [@idempotent_location, count("SELECT count(*) FROM contracts")]
  end

  def test_list_filters_and_paginates
    other = create_customer(@actor, name: "Agência Norte", document: "11144477735")
    first = issued
    @clock.advance(60)
    second = issued(reservation(after_rental, customer: other))
    uc(:cancel_contract).call(@actor, second.id, reason: "Evento adiado")
    page = get!(200, "/contracts", { "limit" => "1" })

    assert_conforms page, "ContractPage"
    assert_equal [[second.code], 2, 1], [page["data"].map { |row| row["code"] }, page["pagination"]["total"], page["pagination"]["next_offset"]]
    assert_equal([first.code], get!(200, "/contracts", { "status" => "issued" })["data"].map { |row| row["code"] })
    assert_equal([second.code], get!(200, "/contracts", { "customer_id" => other.id })["data"].map { |row| row["code"] })
    assert_equal([first.code], get!(200, "/contracts", { "q" => first.code.downcase })["data"].map { |row| row["code"] })
    assert_equal([first.code], get!(200, "/contracts", { "offset" => "1" })["data"].map { |row| row["code"] })
    [[{ "limit" => "0" }, "limite"], [{ "limit" => "101" }, "limite"], [{ "status" => "aberto" }, "situacao"], [{ "customer_id" => "x" }, "cliente"]]
      .each do |params, field|
        get!(422, "/contracts", params)

        assert_equal [field], fields.keys, params.inspect
      end
    get!(403, "/contracts", {}, token: token(%w[reservations.read]))
  end

  def test_detail_with_cancellation_preview
    contract = issued
    @clock.travel_to(t("2026-03-08T20:00:00Z"))
    body = get!(200, "/contracts/#{contract.id}")

    assert_conforms body, "Contract"
    assert_equal({ "fee_bps" => 3000, "fee" => { "amount_cents" => 27_000, "currency" => "BRL", "formatted" => "R$ 270,00" },
                   "base" => { "amount_cents" => 90_000, "currency" => "BRL", "formatted" => "R$ 900,00" }, "hours_before" => 36 },
                 body["cancellation_preview"])
    assert_equal ["America/Sao_Paulo", nil, []], [body["time_zone"], body["cancellation_fee"], body["amendments"]]
    assert_equal D::Organizations::CancellationPolicy::DEFAULT, body["cancellation_policy"]
    refute body["documents"].first.key?("accepted_by_document")
    get!(403, "/contracts/#{contract.id}", {}, token: token(%w[contracts.write]))
  end

  def test_pdf_download_headers_and_integrity
    contract = issued
    get "/api/v1/contracts/#{contract.id}/documents/1", {}, headers(@token)

    assert_equal 200, last_response.status, last_response.body[0, 300]
    body = last_response.body

    assert body.start_with?("%PDF-")
    assert_equal({ "content-type" => "application/pdf",
                   "content-disposition" => %(attachment; filename="contrato-#{contract.code}-v1.pdf"; filename*=UTF-8''contrato-#{contract.code}-v1.pdf),
                   "content-length" => body.bytesize.to_s, "cache-control" => "private, no-store", "x-content-type-options" => "nosniff",
                   "content-security-policy" => "default-src 'none'; sandbox", "repr-digest" => "sha-256=:#{Digest::SHA256.base64digest(body)}:" },
                 pdf_headers)
    sha = owner_query("SELECT sha256 FROM contract_documents WHERE contract_id = $1", [contract.id]).first["sha256"]

    assert_equal sha, Digest::SHA256.hexdigest(body)
  end

  def test_pdf_errors
    contract = issued
    get!(404, "/contracts/#{contract.id}/documents/2")

    assert_error "not_found"
    get!(422, "/contracts/#{contract.id}/documents/0")

    assert_equal({ "versao" => ["informe a versão do documento (número inteiro positivo)"] }, fields)
    get!(422, "/contracts/#{contract.id}/documents/v1")

    assert_error "validation_error"
    get!(404, "/contracts/#{beta_contract.id}/documents/1")

    assert_error "not_found"
    get!(403, "/contracts/#{contract.id}/documents/1", {}, token: token(%w[contracts.write]))

    assert_error "forbidden"
    key = "#{@org[:organization_id]}/#{owner_query("SELECT attachment_id FROM contract_documents").first["attachment_id"]}"
    File.delete(@system.services[:storage].path_for(key))
    get!(404, "/contracts/#{contract.id}/documents/1")

    assert_error "not_found"
  end

  def test_amendment_creates_document_version_and_amount_difference
    contract = issued
    post!(422, "/contracts/#{contract.id}/amendments", { "description" => "Sem fim" })

    assert_equal({ "fim" => ["obrigatório"] }, fields)
    post!(403, "/contracts/#{contract.id}/amendments", { "ends_at" => "2026-03-13T08:00:00Z" }, token: token(%w[contracts.read contracts.write]))

    assert_error "forbidden"
    body = assert_idempotent("/contracts/#{contract.id}/amendments", { "ends_at" => "2026-03-13T08:00:00Z", "description" => "Mais um dia" }, 201,
                             changed_body: { "ends_at" => "2026-03-14T08:00:00Z" })

    assert_conforms body, "ContractAmendmentResult"
    assert_equal [2, %w[amendment issue], 135_000], [body["contract"]["current_document_version"], body["contract"]["documents"].map { |d| d["reason"] },
                                                     body["contract"]["current_total"]["amount_cents"]]
    amendment = body["amendment"]

    assert_equal [1, "extension", "Mais um dia", 45_000, 2],
                 [amendment["number"], amendment["kind"], amendment["description"], amendment["amount_delta"]["amount_cents"], amendment["document_version"]]
    assert_equal "/api/v1/contracts/#{contract.id}", @idempotent_location
    assert_equal 2, count("SELECT count(*) FROM contract_documents")
  end

  def test_amendment_into_another_reservation_is_a_conflict_without_amendment
    contract = issued(confirmed([line(@camera, 3)], rental))
    confirmed([line(@camera, 1)], period("2026-03-12T10:00:00Z", "2026-03-13T08:00:00Z"))
    post!(409, "/contracts/#{contract.id}/amendments", { "ends_at" => "2026-03-13T08:00:00Z" })

    assert_error "unavailable"
    refute_empty json_body["error"]["details"]["shortages"]
    assert_equal [0, 1], [count("SELECT count(*) FROM contract_amendments"), count("SELECT count(*) FROM contract_documents")]
  end

  def test_cancellation_with_fee
    contract = issued
    @clock.travel_to(t("2026-03-08T20:00:00Z"))
    post!(403, "/contracts/#{contract.id}/cancel", { "reason" => "Evento adiado" }, token: token(%w[contracts.read contracts.write]))

    assert_error "forbidden"
    post!(422, "/contracts/#{contract.id}/cancel", {})

    assert_equal ["motivo"], fields.keys
    body = assert_idempotent("/contracts/#{contract.id}/cancel", { "reason" => "Evento adiado" }, 200, changed_body: { "reason" => "Outro" })

    assert_conforms body, "ContractCancellationResult"
    assert_equal ["cancelled", "Evento adiado", 27_000, nil], [body["contract"]["status"], body["contract"]["cancellation_reason"],
                                                               body["contract"]["cancellation_fee"]["amount_cents"], body["contract"]["cancellation_preview"]]
    assert_equal [3000, 27_000, 36], [body["cancellation"]["fee_bps"], body["cancellation"]["fee"]["amount_cents"], body["cancellation"]["hours_before"]]
    fee = owner_query("SELECT amount_cents FROM reservation_adjustments WHERE kind = 'cancellation_fee'").first["amount_cents"].to_i

    assert_equal ["cancelled", 27_000], [uc(:get_reservation).call(@actor, contract.reservation_id)[:reservation].status, fee]
  end

  def test_cancellation_after_pickup_is_refused
    target = confirmed([line(@camera, 1)])
    contract = issued(target)
    pick_up(target)
    post!(409, "/contracts/#{contract.id}/cancel", { "reason" => "Desistência" })

    assert_error "contract_not_cancellable"
    assert_nil get!(200, "/contracts/#{contract.id}")["cancellation_preview"]
  end

  def test_other_organization_contracts_are_not_found
    foreign = beta_contract.id
    get!(404, "/contracts/#{foreign}")

    assert_error "not_found"
    post!(404, "/contracts/#{foreign}/amendments", { "ends_at" => "2026-03-13T08:00:00Z" })
    post!(404, "/contracts/#{foreign}/cancel", { "reason" => "Teste" })

    assert_empty get!(200, "/contracts")["data"]
    get!(422, "/contracts/abc")

    assert_equal({ "id" => ["identificador inválido"] }, fields)
    assert_equal "issued", uc(:get_contract).call(@beta[:actor], foreign)[:contract].status
  end
end
