# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/operations_support"
require_relative "../support/commercial_terms_support"

# Conta somente leitura navega por toda a área da equipe (ADR-031): a lista de páginas vem de todas as rotas
# GET da equipe no Router, com os parâmetros preenchidos por registros criados antes do prazo (reserva,
# orçamento, contrato, cobrança, pagamento, caução, fatura, conciliação, retirada, devolução, avaria,
# manutenção, filial, cliente, produto, ativo, cupom e tarifa). Rota nova sem registro correspondente nem
# exclusão justificada faz o teste falhar.
class EmailConfirmationNavigationTest < HttpTest
  include OperationsSupport
  include CommercialTermsSupport

  EC = Locentra::Domain::Identity::EmailConfirmation
  REFUSED = "Conta somente leitura até a confirmação do e-mail"

  # Rotas GET da equipe que o teste não visita, com o motivo.
  EXCLUDED = {
    "/anexos/:id" => "download do arquivo, sem página; coberto pelos testes de anexos (consulta com read: true)"
  }.freeze

  def setup
    super
    @org = create_organization(name: "Locadora Gama", email: "dona@gama.test")
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    seed_records
    owner_query("UPDATE users SET email_confirmed_at = NULL WHERE id = $1", [@org[:user_id]], tenant: "")
    @clock.advance(EC::GRACE_PERIOD_SECONDS)
    login("dona@gama.test")
  end

  def seed_records
    @camera = create_product(@actor, sku: "CAM-NAV", tracking: "serialized", pricing: { "daily_cents" => 10_000 })
    @assets = register_assets(@actor, @camera, @branch, 2)
    @chairs = create_product(@actor, sku: "CAD-NAV", tracking: "bulk", pricing: { "daily_cents" => 1_000 },
                                     deposit: Locentra::Domain::Money.new(5_000))
    stock(@actor, @chairs, @branch, 20)
    seed_commercial
    seed_operation
    seed_finance
  end

  def seed_commercial
    @quote = uc(:create_quote).call(@actor, { customer_id: @customer.id, branch_id: @branch.id, period: period("2026-03-20T08:00:00Z", "2026-03-21T08:00:00Z"),
                                              lines: [line(@camera, 1)], valid_until: t("2026-03-15T12:00:00Z") })
    @contracted = confirmed([line(@camera, 1)], period("2026-03-22T08:00:00Z", "2026-03-23T08:00:00Z"))
    @contract = uc(:issue_contract).call(@actor, @contracted.id)
    @coupon = create_coupon("NAV10")
    @fee = create_fee("ENTREGA", "Entrega no local", 5_000)
  end

  def seed_operation
    @returned = confirmed([line(@chairs, 2)])
    pick_up(@returned)
    return_all(@returned, requires_inspection: true)
    return_line = owner_query("SELECT id FROM return_lines LIMIT 1").first["id"]
    @damage = uc(:create_damage_report).call(@actor, return_line_id: return_line, description: "estofado rasgado", severity: "minor",
                                                     estimated_cost: Locentra::Domain::Money.new(2_000))
    @out = confirmed([line(@chairs, 1)])
    pick_up(@out)
    @order = uc(:open_maintenance_order).call(@actor, description: "Revisão", asset_id: @assets.last.id)
  end

  def seed_finance
    uc(:sync_reservation_charges).call(@actor, @out.id)
    receivable = uc(:finance).reservation(@actor, @out.id)[:receivables].first[:receivable]
    uc(:register_payment).call(@actor, { purpose: "receivable", receivable_id: receivable.id, method: "cash", amount: Locentra::Domain::Money.new(500) })
    uc(:open_deposit).call(@actor, @out.id, kind: "paid_deposit", amount: Locentra::Domain::Money.new(5_000))
    uc(:issue_invoice).call(@actor, @out.id)
    uc(:configure_payment_account).call(@actor, provider: "simulator", name: "Simulador")
    @report = uc(:reconcile_payments).call(@actor)
  end

  def first_id(table) = owner_query("SELECT id FROM #{table} ORDER BY id LIMIT 1").first&.fetch("id") || raise("sem registro em #{table}")

  def ids
    {
      "/clientes/:id" => @customer.id, "/produtos/:id" => @camera.id, "/ativos/:id" => @assets.first.id, "/reservas/:id" => @out.id,
      "/cupons/:id" => @coupon.id, "/tarifas/:id" => @fee.id, "/orcamentos/:id" => @quote.id,
      "/orcamentos/:id/nova-versao" => @quote.id, "/contratos/:id" => @contract.id, "/organizacao/filiais/:id" => @branch.id,
      "/financeiro/conciliacao/:id" => @report, "/financeiro/cobrancas/:id" => first_id("receivables"),
      "/financeiro/faturas/:id" => first_id("invoices"), "/financeiro/pagamentos/:id" => first_id("payments"),
      "/financeiro/caucoes/:id" => first_id("deposits"), "/operacao/retiradas/:id" => first_id("pickups"),
      "/operacao/reservas/:id/devolucao" => @out.id, "/operacao/devolucoes/:id" => first_id("returns"),
      "/operacao/avarias/:id" => @damage.id, "/manutencao/:id" => @order.id
    }
  end

  def staff_pages
    Locentra::Interfaces::HTTP::App.new(@system).router.routes
                                   .select { |route| route.verb == "GET" && %i[session staff_or_portal].include?(route.auth) }
                                   .map(&:pattern).uniq
  end

  def test_every_staff_page_opens_for_the_read_only_account
    filled = ids
    pages = staff_pages - EXCLUDED.keys
    missing = pages.select { |pattern| pattern.include?(":") && !filled.key?(pattern) }

    assert_empty missing, "rota com parâmetro sem registro no teste nem exclusão justificada"
    assert_empty EXCLUDED.keys - staff_pages, "exclusão de rota inexistente"
    pages.each do |pattern|
      path = pattern.include?(":") ? pattern.sub(":id", filled.fetch(pattern).to_s) : pattern
      get path

      assert_equal 200, last_response.status, "#{path}: #{last_response.body[/<main.*/m].to_s[0, 300]}"
      refute_includes last_response.body, REFUSED, path
      assert_includes last_response.body, "Conta somente leitura até a confirmação.", "#{path}: aviso no topo"
    end
    assert_operator pages.size, :>=, 45, "lista gerada a partir do Router"
  end
end
