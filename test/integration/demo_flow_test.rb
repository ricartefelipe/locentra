# frozen_string_literal: true

require "rack/test"
require "rack/lint"
require_relative "integration_helper"
require_relative "../support/worker_support"
require "locentra/interfaces/http/app"

# Roteiro de demonstração de ponta a ponta, o mesmo de docs/DEMONSTRACAO.md: entrada pela interface
# web, operação pelos casos de uso (os mesmos chamados pelas telas), tarefas pelo worker, repetição
# idempotente pela API e isolamento entre organizações pela interface web e pelo banco.
class DemoFlowTest < DatabaseTest
  include Rack::Test::Methods
  include WorkerHelpers

  PASSWORD = "senha-muito-segura-1"
  UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/

  def app = @app ||= Rack::Lint.new(Locentra::Interfaces::HTTP::App.build(@system))

  def teardown
    @worker_system&.shutdown
    super
  end

  def test_rental_lifecycle_from_quote_to_settlement_with_tenant_isolation
    enter_organization_a
    register_customer_and_catalog
    register_asset_and_stock
    check_availability
    quote_and_reservation
    dispute_last_unit
    issue_contract
    register_pickup
    partial_return_with_damage
    route_items_to_inspection
    finish_return_and_settle_deposit
    confirm_simulated_payment
    repeat_with_idempotency_key
    enter_organization_b_and_check_isolation
  end

  private

  # (1) A usuária pertence a duas organizações: entra, escolhe a organização A e passa a operar nela.
  def enter_organization_a
    @alfa = create_organization(name: "Alfa Audiovisual", email: "ana@alfa.test")
    @beta = create_organization(name: "Beta Eventos", email: "paulo@beta.test")
    join(@beta[:actor], @alfa[:user_id], "ana@alfa.test", "manager")
    sign_in_and_choose(@alfa)

    assert_includes last_response.body, "Alfa Audiovisual"
    @org = @alfa
    @actor = A::Actor.user(user_id: @alfa[:user_id], organization_id: @alfa[:organization_id], role: "owner", request_id: "demo-alfa-0001")
    @branch = @alfa[:branch]
  end

  # (2) Cliente pessoa física, um segundo cliente para a disputa e o catálogo com preços e caução.
  def register_customer_and_catalog
    @customer = uc(:create_customer).call(@actor, { kind: "individual", name: "Marina Souza", document: "52998224725", email: "marina@cliente.test" })
    @rival = uc(:create_customer).call(@actor, { kind: "company", name: "Produtora Horizonte Ltda.", document: "11222333000181",
                                                 email: "contato@horizonte.test" })
    @camera = create_product(@actor, sku: "CAM-FX6", name: "Câmera Sony FX6", tracking: "serialized", pricing: { "daily_cents" => 45_000 },
                                     deposit: D::Money.new(100_000), replacement_cost: D::Money.new(1_200_000))
    @tripods = create_product(@actor, sku: "TRIPE-PRO", name: "Tripé profissional", tracking: "bulk", pricing: { "daily_cents" => 3_000 })

    assert_equal(%w[CAM-FX6 TRIPE-PRO], uc(:list_products).call(@actor).items.map(&:sku).sort)
  end

  # (3) Ativos individuais (patrimônio) e estoque quantitativo.
  def register_asset_and_stock
    @assets = register_assets(@actor, @camera, @branch, 2, prefix: "CAM-FX6")
    stock(@actor, @tripods, @branch, 6)

    assert_equal(%w[CAM-FX6-1 CAM-FX6-2], @assets.map(&:tag))
    assert_equal(%w[available available], @assets.map { |asset| asset_status(asset.id) })
  end

  # (4) Disponibilidade no período da locação.
  def check_availability
    assert_equal [2, 6], [available(@camera), available(@tripods)]
  end

  # (5) Orçamento enviado, aprovado e convertido (conversão idempotente) em reserva confirmada.
  def quote_and_reservation
    quote = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, period: rental, valid_until: t("2026-03-05T12:00:00Z"),
                                             lines: [line(@camera, 1), line(@tripods, 4)], terms: "Retirada e devolução na loja." })
    uc(:send_quote).call(@actor, quote.id)
    uc(:approve_quote).call(@actor, quote.id, version: 1, approver_name: "Marina Souza")
    converted = uc(:convert_quote).call(@actor, quote.id)
    @reservation = converted.reservation

    assert converted.created
    assert_equal ["confirmed", "quote", 114_000, 100_000], [@reservation.status, @reservation.source, @reservation.total.cents, @reservation.deposit.cents]
    assert_equal @reservation.id, uc(:convert_quote).call(@actor, quote.id).reservation.id, "converter de novo devolve a mesma reserva"
    assert_equal [1, 2], [available(@camera), available(@tripods)]
  end

  # (6) Dois bloqueios simultâneos disputam a última câmera: um vence, o outro recebe falta de
  # disponibilidade; a confirmação de uma solicitação incompatível é recusada.
  def dispute_last_unit
    request = reserve(@actor, @rival, @branch, rental, [line(@camera, 1)], mode: "request")
    outcomes = simultaneously(2) { reserve(@actor, @rival, @branch, rental, [line(@camera, 1)], mode: "hold", hold_minutes: 60) }
    errors, holds = outcomes.partition { |outcome| outcome.is_a?(StandardError) }

    assert_equal 1, holds.size, "exatamente um bloqueio fica com a última unidade"
    assert_kind_of D::Unavailable, errors.first
    assert_equal 0, available(@camera)
    assert_raises(D::Unavailable) { uc(:confirm_reservation).call(@actor, request.id) }
    assert_equal "requested", status_of(request)
    assert_operator @system.metrics.counter_value("domain_conflicts_total", code: "unavailable"), :>=, 2
  end

  # (7) Contrato com termos congelados e PDF gerado a partir dos dados reais.
  def issue_contract
    contract = uc(:issue_contract).call(@actor, @reservation.id)
    data = uc(:get_contract).call(@actor, contract.id)
    _, bytes = uc(:download_attachment).call(@actor, data[:documents].first["attachment_id"])

    assert_match(/\AC-\d{6}\z/, contract.code)
    assert bytes.start_with?("%PDF")
    assert_equal [114_000, 100_000], data[:contract].terms.values_at("contracted_total_cents", "deposit_cents")
  end

  # (8) Caução recebida e retirada conferida e entregue ao próprio cliente.
  def register_pickup
    @clock.travel_to(t("2026-03-10T12:00:00Z"))
    @deposit = uc(:open_deposit).call(@actor, @reservation.id, kind: "paid_deposit")
    uc(:register_payment).call(@actor, { purpose: "deposit", deposit_id: @deposit.id, method: "pix", amount: D::Money.new(100_000) })
    pickup = uc(:start_pickup).call(@actor, @reservation.id)
    lines = uc(:get_pickup).call(@actor, pickup.id)[:lines]
    entries = lines.map do |l|
      l["asset_id"] ? { line_id: l["id"], tag: l["allocated_tag"] } : { line_id: l["id"], quantity: l["expected_quantity"] }
    end
    uc(:check_pickup).call(@actor, pickup.id, entries)
    uc(:deliver_pickup).call(@actor, pickup.id, picker: { kind: "customer" })
    @camera_asset = lines.find { |l| l["asset_id"] }["asset_id"]

    assert_equal "in_progress", status_of(@reservation)
    assert_equal "checked_out", asset_status(@camera_asset)
  end

  # (9) Devolução parcial: câmera avariada (vai para inspeção e abre registro de avaria) e dois tripés.
  def partial_return_with_damage
    @clock.travel_to(t("2026-03-11T12:00:00Z"))
    register_return(camera: { outcome: "damaged", quantity: 1, notes: "Tela trincada" }, tripods: { outcome: "ok", quantity: 2 })
    @report = uc(:list_damage_reports).call(@actor).first

    assert_equal "in_progress", status_of(@reservation), "dois tripés ainda estão com o cliente"
    assert_equal "in_inspection", asset_status(@camera_asset)
    assert_equal %w[damage open], @report.values_at("kind", "status")
  end

  # (10) Um tripé devolvido é encaminhado para inspeção; a avaria é cobrada com evidência; a inspeção do
  # tripé libera a unidade e a da câmera é reprovada, abrindo ordem de manutenção.
  def route_items_to_inspection
    register_return(tripods: { outcome: "ok", quantity: 1, requires_inspection: true, notes: "Trava frouxa" })
    pending = uc(:list_inspections).call(@actor)

    assert_equal [@camera_asset, nil].sort_by(&:to_s), pending.map { |i| i["asset_id"] }.sort_by(&:to_s)
    report = uc(:get_damage_report).call(@actor, @report["id"])[:report]
    uc(:upload_attachment).call(@actor, owner_type: "damage_report", owner_id: report.id, filename: "tela.png", bytes: "\x89PNG\r\n\x1A\nfoto".b)
    uc(:approve_damage_charge).call(@actor, report.id, version: report.version, amount: D::Money.new(35_000))
    uc(:approve_inspection).call(@actor, pending.find { |i| i["stock_pool_id"] }["id"], notes: "Trava ajustada")
    uc(:reject_inspection).call(@actor, pending.find { |i| i["asset_id"] }["id"], notes: "Tela precisa de troca", description: "Troca da tela")

    assert_equal "in_maintenance", asset_status(@camera_asset)
    assert_equal(["open"], uc(:list_maintenance_orders).call(@actor).map { |order| order["status"] })
  end

  # (11) O último tripé volta, a reserva é concluída e a caução quita a avaria; o saldo é devolvido.
  def finish_return_and_settle_deposit
    @clock.travel_to(t("2026-03-12T10:00:00Z"))
    register_return(tripods: { outcome: "ok", quantity: 1 })
    drain

    assert_equal "completed", status_of(@reservation)
    damage = receivable("damage")

    assert_equal 35_000, damage.amount.cents
    uc(:move_deposit).apply(@actor, @deposit.id, receivable_id: damage.id, amount: D::Money.new(35_000))
    uc(:move_deposit).give_back(@actor, @deposit.id, amount: D::Money.new(65_000), method: "pix", notes: "Saldo da caução")
    ledger = uc(:finance).deposit(@actor, @deposit.id)[:ledger]

    assert_equal ["settled", 0], [ledger.status, ledger.balance.cents]
    assert_equal "paid", balance(damage).status
  end

  # (12) Cobrança da locação pelo provedor simulado: envio pelo worker, confirmação pelo evento do
  # provedor e saldo restante de R$ 100,00.
  def confirm_simulated_payment
    uc(:configure_payment_account).call(@actor, provider: "simulator", name: "Simulador local")
    @rental = receivable("rental")
    requested = uc(:request_payment).call(@actor, { purpose: "receivable", receivable_id: @rental.id, method: "pix", amount: D::Money.new(104_000),
                                                    scenario: "success" })
    drain

    assert_equal "pending", uc(:finance).payment(@actor, requested.id)[:payment].status
    assert_equal :accepted, uc(:simulate_payment).call(@actor, requested.id)
    drain

    assert_equal "confirmed", uc(:finance).payment(@actor, requested.id)[:payment].status
    assert_equal ["partial", 10_000], [balance(@rental).status, balance(@rental).outstanding.cents]
  end

  # (13) O mesmo pagamento enviado duas vezes pela API com a mesma chave é registrado uma única vez.
  def repeat_with_idempotency_key
    token = uc(:create_credential).call(@actor, name: "ERP da Alfa", scopes: %w[finance.read finance.write], expires_in_days: 30)["token"]
    payload = { "receivable_id" => @rental.id, "method" => "pix", "amount_cents" => 10_000, "notes" => "Pix do saldo" }
    first = api_payment(token, payload, "demo-saldo-0001")
    second = api_payment(token, payload, "demo-saldo-0001")

    assert_equal [201, 201], [first.status, second.status]
    assert_equal "true", second.headers["idempotent-replayed"]
    assert_equal JSON.parse(first.body)["id"], JSON.parse(second.body)["id"]
    assert_equal 409, api_payment(token, payload.merge("amount_cents" => 1), "demo-saldo-0001").status
    assert_equal 1, owner_query("SELECT count(*) AS n FROM payments WHERE receivable_id = $1 AND provider = 'manual'", [@rental.id]).first["n"].to_i
    assert_equal "paid", balance(@rental).status
    assert_empty @system.transactor.call(tenant_id: @alfa[:organization_id]) { |tx| @system.repos[:ledger_entries].unbalanced_transactions(tx) }
  end

  # (14) Na organização B, nada da organização A é visível: telas, casos de uso e banco (RLS).
  def enter_organization_b_and_check_isolation
    sign_in_and_choose(@beta)

    assert_includes last_response.body, "Beta Eventos"
    get "/reservas/#{@reservation.id}"

    assert_equal 404, last_response.status
    get "/clientes"

    refute_includes last_response.body, "Marina Souza"
    beta = A::Actor.user(user_id: @alfa[:user_id], organization_id: @beta[:organization_id], role: "manager")

    assert_raises(D::NotFound) { uc(:get_reservation).call(beta, @reservation.id) }
    assert_raises(D::NotFound) { uc(:get_customer).call(beta, @customer.id) }
    assert_equal 0, uc(:list_reservations).call(beta).total
    assert_equal 0, owner_query("SELECT count(*) AS n FROM reservations", tenant: @beta[:organization_id]).first["n"].to_i
    assert_operator owner_query("SELECT count(*) AS n FROM reservations", tenant: @alfa[:organization_id]).first["n"].to_i, :>=, 3
  end

  # --- Apoio -----------------------------------------------------------------------------------

  def rental = period("2026-03-10T12:00:00Z", "2026-03-12T12:00:00Z")

  def available(product)
    uc(:check_availability).call(@actor, branch_id: @branch.id, period: rental, product_ids: [product.id]).first["available"]
  end

  def status_of(reservation) = uc(:get_reservation).call(@actor, reservation.id)[:reservation].status
  def asset_status(id) = owner_query("SELECT status FROM assets WHERE id = $1", [id]).first["status"]
  def receivable(kind) = uc(:finance).reservation(@actor, @reservation.id)[:receivables].find { |row| row[:receivable].kind == kind }[:receivable]
  def balance(receivable) = uc(:finance).receivable(@actor, receivable.id)[:balance]

  def join(inviter, user_id, email, role)
    invitation = uc(:invite_member).call(inviter, email: email, role: role)
    token = "#{inviter.organization_id}.demo-#{SecureRandom.hex(12)}"
    @system.uow.run(inviter) do |tx, _|
      tx.execute("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invitation["id"]])
    end
    uc(:accept_invitation).call(token: token, user_id: user_id)
  end

  def sign_in_and_choose(organization)
    post "/entrar", { "email" => "ana@alfa.test", "senha" => PASSWORD }

    assert_equal "/organizacoes", last_response.location, "duas organizações: a escolha é explícita"
    follow_redirect!
    token = last_response.body[/name="_csrf" value="([^"]+)"/, 1]
    post "/organizacoes/ativar", { "_csrf" => token, "organizacao_id" => organization[:organization_id] }
    follow_redirect!

    assert_equal 200, last_response.status
  end

  def register_return(camera: nil, tripods: nil)
    lines = uc(:return_form).call(@actor, @reservation.id)[:lines]
    pairs = [[camera, lines.find { |l| l["asset_id"] }], [tripods, lines.find { |l| l["stock_pool_id"] }]]
    entries = pairs.filter_map { |spec, l| spec && { pickup_line_id: l["id"], **spec } }
    uc(:register_return).call(@actor, @reservation.id, entries: entries)
  end

  # Executa o bloco em `count` threads liberadas ao mesmo tempo e devolve resultados ou exceções.
  def simultaneously(count)
    gate = Queue.new
    threads = Array.new(count) do
      Thread.new do
        gate.pop
        yield
      rescue StandardError => e
        e
      end
    end
    count.times { gate << :go }
    threads.map(&:value)
  end

  def api_payment(token, payload, key)
    post "/api/v1/payments", JSON.generate(payload), { "HTTP_AUTHORIZATION" => "Bearer #{token}", "CONTENT_TYPE" => "application/json",
                                                       "HTTP_IDEMPOTENCY_KEY" => key }
    last_response
  end
end
