# frozen_string_literal: true

require_relative "http_helper"
require_relative "../support/operations_support"

# Formulários complementares: aprovação de inspeção, avaria manual, descarte, manutenção e transferência de
# estoque, cancelamento de separação e retirada por contato autorizado.
class OperationsFormsTest < HttpTest
  include OperationsSupport

  def setup
    super
    @org = create_organization(email: "dona@alfa.test")
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor, name: "Produtora Sul", document: "11222333000181", kind: "company")
    @contact = uc(:add_contact).call(@actor, @customer.id, { name: "Rita Retirante", document: "11144477735", authorized_pickup: true })
    @camera = create_product(@actor, sku: "CAM-FRM", tracking: "serialized")
    register_assets(@actor, @camera, @branch, 1)
    @chairs = create_product(@actor, sku: "CAD-FRM", tracking: "bulk", pricing: { "daily_cents" => 500 })
    stock(@actor, @chairs, @branch, 10)
    login("dona@alfa.test")
  end

  def test_contact_picker_and_separation_cancel
    reservation = confirmed([line(@camera, 1)])
    pickup = uc(:start_pickup).call(@actor, reservation.id)
    get "/operacao/retiradas/#{pickup.id}"

    assert_includes last_response.body, "Rita Retirante"
    refute_includes last_response.body, %(value="cliente"), "pessoa jurídica retira somente por contato"
    post_form "/operacao/retiradas/#{pickup.id}/cancelar", { "motivo" => "" }

    assert_equal 422, last_response.status
    post_form "/operacao/retiradas/#{pickup.id}/cancelar", { "motivo" => "cliente remarcou" }

    assert_equal "/reservas/#{reservation.id}", last_response.location
    fresh = uc(:start_pickup).call(@actor, reservation.id)
    uc(:check_pickup).call(@actor, fresh.id, check_entries(@actor, fresh))
    get "/operacao/retiradas/#{fresh.id}"
    post_form "/operacao/retiradas/#{fresh.id}/entregar", { "retirante" => "" }

    assert_equal 422, last_response.status
    post_form "/operacao/retiradas/#{fresh.id}/entregar", { "retirante" => @contact.id }
    follow_redirect!

    assert_includes last_response.body, "Retirada registrada para Rita Retirante"
    assert_includes last_response.body, "111.444.777-35"
  end

  def test_inspection_approval_manual_damage_report_and_dismissal
    reservation = confirmed([line(@chairs, 3)])
    pick_up(reservation, picker: { kind: "contact", contact_id: @contact.id })
    return_all(reservation, requires_inspection: true)
    inspection = uc(:list_inspections).call(@actor).first
    get "/operacao/inspecoes"

    assert_includes last_response.body, "Registrar avaria encontrada na inspeção"
    post_form "/operacao/avarias", { "item" => inspection["return_line_id"], "descricao" => "x", "severidade" => "minor" }

    assert_equal "/operacao/inspecoes", last_response.location
    post_form "/operacao/avarias", { "item" => inspection["return_line_id"], "descricao" => "Assentos manchados", "severidade" => "minor",
                                     "custo" => "45,00" }
    report_path = last_response.location
    follow_redirect!

    assert_includes last_response.body, "Avaria AV-000001 registrada"
    post_form "#{report_path}/descartar", { "motivo" => "limpeza resolveu" }
    follow_redirect!

    assert_includes last_response.body, "Registro descartado sem cobrança"
    get "/operacao/inspecoes"
    post_form "/operacao/inspecoes/#{inspection["id"]}/aprovar", { "observacoes" => "limpas" }
    follow_redirect!

    assert_includes last_response.body, "Inspeção aprovada"
    post_form "/operacao/inspecoes/#{inspection["id"]}/aprovar", {}

    assert_equal 409, last_response.status
    assert_equal 10, available(@chairs)
  end

  def test_stock_maintenance_and_stock_transfer_forms
    north = uc(:create_branch).call(@actor, name: "Filial Norte", code: "NORTE")
    get "/manutencao"
    post_form "/manutencao", { "produto_id" => @chairs.id, "filial_id" => @branch.id, "quantidade" => "20", "descricao" => "Reparo" }

    assert_equal 409, last_response.status
    assert_includes last_response.body, "disponível: 10"
    post_form "/manutencao", { "produto_id" => @chairs.id, "filial_id" => @branch.id, "quantidade" => "2", "descricao" => "Reparo de pés" }
    order_path = last_response.location
    follow_redirect!

    assert_includes last_response.body, "Reparo de pés"
    post_form "#{order_path}/iniciar", {}
    follow_redirect!
    post_form "#{order_path}/concluir", { "custo" => "30,00", "inspecao" => "1" }
    follow_redirect!

    assert_includes last_response.body, "o item segue para inspeção"
    get "/transferencias"
    post_form "/transferencias", { "produto_id" => @chairs.id, "origem_id" => @branch.id, "destino_id" => north.id, "quantidade" => "3" }
    follow_redirect!
    transfer = uc(:list_transfers).call(@actor).first
    post_form "/transferencias/#{transfer["id"]}/cancelar", { "motivo" => "" }

    assert_equal 422, last_response.status
    post_form "/transferencias/#{transfer["id"]}/cancelar", { "motivo" => "pedido duplicado" }
    follow_redirect!

    assert_includes last_response.body, "Transferência cancelada"
    assert_includes last_response.body, "pedido duplicado"
  end
end
