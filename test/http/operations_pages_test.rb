# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/operations_support"

# Telas de retirada, devolução, inspeção, avarias, manutenção e transferências (Rack::Lint ativo).
class OperationsPagesTest < HttpTest
  include OperationsSupport

  def setup
    super
    @org = create_organization(email: "dona@alfa.test")
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-WEB", tracking: "serialized")
    @assets = register_assets(@actor, @camera, @branch, 2)
    @chairs = create_product(@actor, sku: "CAD-WEB", tracking: "bulk", pricing: { "daily_cents" => 500 })
    stock(@actor, @chairs, @branch, 10)
    login("dona@alfa.test")
  end

  def get_ok(path)
    get path
  rescue Rack::Lint::LintError => e
    flunk "#{path}: #{e.message}"
  else
    assert_equal 200, last_response.status, "#{path}: #{last_response.body[0, 400]}"
  end

  def test_every_operations_page_renders
    north = uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    open = confirmed([line(@camera, 1)])
    pickup = uc(:start_pickup).call(@actor, open.id)
    returned = confirmed([line(@camera, 1), line(@chairs, 2)], after_rental)
    pick_up(returned)
    receipt = return_all(returned, outcome: "damaged", notes: "<b>arranhado</b>")
    report = uc(:list_damage_reports).call(@actor).first
    order = uc(:open_maintenance_order).call(@actor, product_id: @chairs.id, branch_id: @branch.id, quantity: 1, description: "Reparo")
    uc(:request_transfer).call(@actor, product_id: @chairs.id, from_branch_id: @branch.id, to_branch_id: north.id, quantity: 1)

    ["/operacao", "/operacao/retiradas/#{pickup.id}", "/operacao/reservas/#{returned.id}/devolucao", "/operacao/devolucoes/#{receipt["id"]}",
     "/operacao/inspecoes", "/operacao/avarias", "/operacao/avarias/#{report["id"]}", "/manutencao", "/manutencao/#{order.id}",
     "/transferencias", "/transferencias?ativo=#{@assets.first.tag}", "/reservas/#{open.id}", "/reservas/#{returned.id}",
     "/ativos/#{@assets.first.id}"].each { |path| get_ok(path) }

    get "/operacao/devolucoes/#{receipt["id"]}"

    refute_includes last_response.body, "<b>arranhado</b>"
    assert_includes last_response.body, "&lt;b&gt;arranhado&lt;/b&gt;"
    get "/"

    assert_includes last_response.body, %(href="/operacao")
    assert_includes last_response.body, %(href="/manutencao")
  end

  def test_pickup_through_the_web_interface
    reservation = confirmed([line(@camera, 1), line(@chairs, 4)])
    get "/reservas/#{reservation.id}"

    assert_includes last_response.body, "Iniciar retirada"
    post_form "/operacao/reservas/#{reservation.id}/retirada", {}

    assert_equal 303, last_response.status
    pickup_path = last_response.location
    follow_redirect!
    lines = uc(:get_pickup).call(@actor, pickup_path.split("/").last)[:lines]
    camera = lines.find { |l| l["asset_id"] }
    chairs = lines.find { |l| l["stock_pool_id"] }
    post_form "#{pickup_path}/conferir", { "patrimonio" => { camera["id"] => "NAO-EXISTE" } }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "NAO-EXISTE não encontrado"
    post_form "#{pickup_path}/entregar", { "retirante" => "cliente" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "confira ao menos um item"
    post_form "#{pickup_path}/conferir", { "patrimonio" => { camera["id"] => camera["allocated_tag"] }, "quantidade" => { chairs["id"] => "3" } }
    follow_redirect!

    assert_includes last_response.body, "Conferência registrada"
    post_form "#{pickup_path}/entregar", { "retirante" => "cliente", "observacoes" => "retirada no balcão" }

    assert_equal "/reservas/#{reservation.id}", last_response.location
    follow_redirect!

    assert_includes last_response.body, "Registrar devolução"
    assert_includes last_response.body, "Em andamento"
  end

  def test_partial_and_final_return_through_the_web_interface
    reservation = confirmed([line(@camera, 1), line(@chairs, 4)])
    pick_up(reservation, quantities: { "CAD-WEB" => 3 })
    path = "/operacao/reservas/#{reservation.id}/devolucao"
    pending = pending_lines(reservation)
    camera_line = pending.find { |l| l["asset_id"] }
    chairs_line = pending.find { |l| l["stock_pool_id"] }
    get path
    post_form path, { "resultado" => { camera_line["id"] => "ok" }, "quantidade" => { camera_line["id"] => "1" } }

    assert_equal 303, last_response.status
    follow_redirect!

    assert_includes last_response.body, "Devolução parcial registrada"
    get path
    post_form path, { "resultado" => { chairs_line["id"] => "missing" }, "quantidade" => { chairs_line["id"] => "3" } }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "descreva a avaria ou a falta"
    post_form path, { "resultado" => { chairs_line["id"] => "ok" }, "quantidade" => { chairs_line["id"] => "3" }, "inspecao" => { chairs_line["id"] => "1" } }
    follow_redirect!

    assert_includes last_response.body, "Devolução concluída"
    assert_equal "completed", reservation_status(reservation)
    assert_equal 1, uc(:list_inspections).call(@actor).size
  end

  def damaged_return
    reservation = confirmed([line(@camera, 1)])
    pick_up(reservation)
    return_all(reservation, outcome: "damaged", notes: "lente riscada")
    reservation
  end

  def test_damage_charge_approval_requires_evidence_through_forms
    damaged_return
    report = uc(:list_damage_reports).call(@actor).first
    get "/operacao/avarias/#{report["id"]}"
    post_form "/operacao/avarias/#{report["id"]}/aprovar", { "valor" => "150,00" }

    assert_equal 422, last_response.status
    assert_includes last_response.body, "anexe ao menos uma evidência"
    pdf = Rack::Test::UploadedFile.new(StringIO.new("%PDF-1.4\n%laudo\n"), "application/pdf", original_filename: "laudo.pdf")
    post "/anexos", { "_csrf" => csrf, "dono_tipo" => "damage_report", "dono_id" => report["id"], "arquivo" => pdf }

    assert_equal "/operacao/avarias/#{report["id"]}", last_response.location
    follow_redirect!
    post_form "/operacao/avarias/#{report["id"]}", { "descricao" => "lente riscada", "severidade" => "severe", "custo" => "120,00" }
    follow_redirect!

    assert_includes last_response.body, "Registro atualizado"
    post_form "/operacao/avarias/#{report["id"]}/aprovar", { "valor" => "150,00" }
    follow_redirect!

    assert_includes last_response.body, "Cobrança de R$ 150,00 aprovada"
  end

  def test_inspection_rejection_and_maintenance_through_forms
    damaged_return
    inspection = uc(:list_inspections).call(@actor).first
    get "/operacao/inspecoes"
    post_form "/operacao/inspecoes/#{inspection["id"]}/reprovar", { "motivo" => "lente riscada", "servico" => "Polimento da lente" }

    assert_match %r{/manutencao/}, last_response.location
    order_path = last_response.location
    follow_redirect!

    assert_includes last_response.body, "Polimento da lente"
    post_form "#{order_path}/iniciar", {}
    follow_redirect!
    post_form "#{order_path}/concluir", { "custo" => "abc" }

    assert_equal 422, last_response.status
    post_form "#{order_path}/concluir", { "custo" => "80,00", "observacoes" => "lente polida" }
    follow_redirect!

    assert_includes last_response.body, "o item está disponível"
    assert_includes last_response.body, "R$ 80,00"
    assert_equal "available", asset_status(owner_query("SELECT asset_id FROM inspections").first["asset_id"])
  end

  def test_maintenance_and_transfer_forms
    north = uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    asset = @assets.first
    get "/manutencao"
    post_form "/manutencao", { "patrimonio" => "INEXISTENTE", "descricao" => "Revisão" }

    assert_equal 404, last_response.status
    post_form "/manutencao", { "patrimonio" => asset.tag.downcase, "descricao" => "Revisão geral" }
    order_path = last_response.location
    follow_redirect!

    assert_includes last_response.body, "Revisão geral"
    post_form "#{order_path}/cancelar", { "motivo" => "aberta por engano" }
    follow_redirect!

    assert_includes last_response.body, "Ordem cancelada"
    get "/transferencias"
    post_form "/transferencias", { "patrimonio" => asset.tag, "destino_id" => @branch.id }

    assert_equal 422, last_response.status
    post_form "/transferencias", { "patrimonio" => asset.tag, "destino_id" => north.id }
    follow_redirect!

    assert_includes last_response.body, "Transferência TR-000001 solicitada"
    transfer = uc(:list_transfers).call(@actor).first
    post_form "/transferencias/#{transfer["id"]}/saida", {}
    follow_redirect!

    assert_includes last_response.body, "item em trânsito"
    post_form "/transferencias/#{transfer["id"]}/saida", {}

    assert_equal 409, last_response.status
    post_form "/transferencias/#{transfer["id"]}/recebimento", {}
    follow_redirect!

    assert_includes last_response.body, "Recebimento registrado"
    assert_equal north.id, owner_query("SELECT branch_id FROM assets WHERE id = $1", [asset.id]).first["branch_id"]
  end

  def test_alert_resolution_and_permissions
    late = confirmed([line(@camera, 1)])
    future = confirmed([line(@camera, 1)], after_rental, customer: create_customer(@actor, name: "Outro", document: "11144477735"))
    owner_query("UPDATE asset_allocations SET asset_id = (SELECT asset_id FROM asset_allocations WHERE reservation_id = $1) WHERE reservation_id = $2",
                [late.id, future.id])
    pick_up(late)
    @clock.travel_to(t("2026-03-04T12:00:00Z"))
    uc(:detect_overdue).call(system_actor)
    login("dona@alfa.test")
    get "/operacao"

    assert_includes last_response.body, "Devolução em atraso"
    assert_includes last_response.body, "Reserva afetada por atraso"
    alert = uc(:operations_board).call(@actor)[:alerts].find { |a| a["kind"] == "affected_by_overdue" }
    post_form "/operacao/alertas/#{alert["id"]}/resolver", { "decisao" => "x" }

    assert_equal 422, last_response.status
    post_form "/operacao/alertas/#{alert["id"]}/resolver", { "decisao" => "Trocar por outra unidade", "voltar" => "/reservas/#{future.id}" }

    assert_equal "/reservas/#{future.id}", last_response.location
    post_form "/sair", {}
    auditor_login
    get "/"

    refute_includes last_response.body, %(href="/operacao")
    refute_includes last_response.body, %(href="/manutencao")
    get "/operacao"

    assert_equal 200, last_response.status
    refute_includes last_response.body, "Resolver"
    post_form "/operacao/reservas/#{future.id}/retirada", {}

    assert_equal 403, last_response.status
  end

  def test_other_tenant_operations_are_not_found
    reservation = confirmed([line(@camera, 1)])
    pickup = uc(:start_pickup).call(@actor, reservation.id)
    post_form "/sair", {}
    create_organization(name: "Locadora Beta", email: "beta@example.test")
    login("beta@example.test")

    ["/operacao/retiradas/#{pickup.id}", "/operacao/reservas/#{reservation.id}/devolucao"].each do |path|
      get path

      assert_equal 404, last_response.status, path
    end
    post_form "/operacao/reservas/#{reservation.id}/retirada", {}

    assert_equal 404, last_response.status
  end

  private

  def auditor_login
    invite = uc(:invite_member).call(@actor, email: "auditor@alfa.test", role: "auditor")
    token = "#{@org[:organization_id]}.convite-#{invite["id"]}"
    owner_query("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invite["id"]])
    uc(:accept_invitation).call(token: token, name: "Auditoria", password: "senha-muito-segura-4")
    login("auditor@alfa.test", "senha-muito-segura-4")
  end
end
