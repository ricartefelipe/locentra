# frozen_string_literal: true

module Locentra
  # Dados demonstrativos idempotentes: duas organizações independentes, executados pelos mesmos
  # casos de uso da aplicação (papel de aplicação, RLS e auditoria ativos). Uma organização já
  # existente (identificada pelo e-mail do proprietário) não é recriada. Depois das organizações, o
  # preparo da demonstração manual (vínculo da proprietária da Alfa com a Beta e conta do simulador
  # de pagamentos da Alfa) é verificado e completado, sem alterar o resumo devolvido.
  class Seed
    PASSWORD = "locentra-local-demo"
    D = Domain

    ORGANIZATIONS = [
      {
        name: "Alfa Audiovisual", owner: ["Ana Ribeiro", "ana@alfa.demo"], plan: "profissional",
        members: [["Bruno Atendimento", "bruno@alfa.demo", "attendant"], ["Carla Estoque", "carla@alfa.demo", "stock_operator"],
                  ["Diego Financeiro", "diego@alfa.demo", "finance"], ["Elisa Auditoria", "elisa@alfa.demo", "auditor"]],
        customers: [["company", "Produtora Horizonte Ltda.", "11222333000181", "contato@horizonte.demo"],
                    ["individual", "Marina Souza", "52998224725", "marina@cliente.demo"]],
        serialized: [["CAM-FX6", "Câmera Sony FX6", 3, { "daily_cents" => 45_000, "weekly_cents" => 225_000, "hourly_cents" => 9_000 }, 300_000],
                     ["LEN-2470", "Lente 24-70mm f/2.8", 2, { "daily_cents" => 12_000, "daily_mode" => "calendar_day" }, 80_000]],
        bulk: [["TRIPE-PRO", "Tripé profissional", 10, { "daily_cents" => 3_000 }], ["LED-PAINEL", "Painel de LED", 8, { "daily_cents" => 5_000 }]],
        kit: ["KIT-FILMAGEM", "Kit filmagem completo", { "daily_cents" => 55_000 }, [["CAM-FX6", 1], ["LEN-2470", 1], ["TRIPE-PRO", 1]]]
      },
      {
        name: "Beta Eventos", owner: ["Paulo Mendes", "paulo@beta.demo"], plan: "essencial",
        members: [["Rita Atendimento", "rita@beta.demo", "attendant"]],
        customers: [["company", "Casamentos Primavera ME", "45723174000110", "eventos@primavera.demo"]],
        serialized: [["GER-5K", "Gerador 5 kVA", 2, { "daily_cents" => 35_000 }, 150_000]],
        bulk: [["CADEIRA", "Cadeira de evento", 120, { "daily_cents" => 800, "quantity_tiers" => [{ "min_quantity" => 50, "discount_bps" => 1000 }] }],
               ["MESA-RED", "Mesa redonda", 20, { "daily_cents" => 2_500 }]],
        kit: ["KIT-MESA", "Mesa com 8 cadeiras", { "daily_cents" => 8_000 }, [["MESA-RED", 1], ["CADEIRA", 8]]]
      }
    ].freeze

    def initialize(system)
      @system = system
    end

    # Acesso extra da demonstração manual (docs/DEMONSTRACAO.md): a proprietária da Alfa também é
    # gerente da Beta, para exercitar a escolha e a troca de organização e o isolamento entre elas.
    DEMO_MEMBERSHIP = { owner: "ana@alfa.demo", organization: "Beta Eventos", role: "manager" }.freeze
    DEMO_SIMULATOR = { organization: "Alfa Audiovisual", name: "Simulador local" }.freeze

    def run
      summaries = ORGANIZATIONS.map { |spec| seed_organization(spec) }
      prepare_demonstration
      summaries
    end

    private

    def uc(name) = @system.use_cases[name]

    # Idempotente também em bancos semeados antes da demonstração: cada item é verificado antes de ser
    # criado (vínculo ativo; conta do simulador ativa).
    def prepare_demonstration
      owners = ORGANIZATIONS.to_h { |spec| [spec[:name], owner_actor(spec)] }
      return if owners.values.any?(&:nil?)

      ensure_membership(owners.fetch(DEMO_MEMBERSHIP[:organization]), DEMO_MEMBERSHIP[:owner], DEMO_MEMBERSHIP[:role])
      ensure_simulator(owners.fetch(DEMO_SIMULATOR[:organization]))
    end

    def owner_actor(spec)
      user = @system.uow.anonymous { |tx| @system.repos[:users].find_by_email(tx, spec[:owner].last) }
      membership = user && uc(:list_memberships).call(user["id"]).find { |m| m["name"] == spec[:name] && m["role"] == "owner" }
      membership && Application::Actor.user(user_id: user["id"], organization_id: membership["organization_id"], role: "owner")
    end

    def ensure_membership(inviter, email, role)
      user = @system.uow.anonymous { |tx| @system.repos[:users].find_by_email(tx, email) }
      return unless user
      return if uc(:list_memberships).call(user["id"]).any? { |m| m["organization_id"] == inviter.organization_id }

      token = invite_with_known_token(inviter, email, role)
      uc(:accept_invitation).call(token: token, user_id: user["id"])
    end

    def ensure_simulator(actor)
      return if uc(:finance).accounts(actor).any? { |account| account["active"] && account["provider"] == "simulator" }

      uc(:configure_payment_account).call(actor, provider: "simulator", name: DEMO_SIMULATOR[:name])
    end

    def seed_organization(spec)
      owner_email = spec[:owner].last
      existing = @system.uow.anonymous { |tx| @system.repos[:users].find_by_email(tx, owner_email) }
      return summary(spec, existing["id"], skipped: true) if existing

      result = uc(:sign_up).call(name: spec[:owner].first, email: owner_email, password: PASSWORD, organization_name: spec[:name], plan_id: spec[:plan])
      actor = Application::Actor.user(user_id: result[:user_id], organization_id: result[:organization_id], role: "owner")
      confirm_owner(result[:user_id])
      branch = uc(:get_organization).call(actor)[:branches].first
      spec[:members].each { |name, email, role| add_member(actor, name, email, role) }
      customers = spec[:customers].map do |kind, name, document, email|
        uc(:create_customer).call(actor, { kind: kind, name: name, document: document, email: email })
      end
      products = seed_catalog(actor, branch, spec)
      seed_reservations(actor, branch, customers, products)
      summary(spec, result[:user_id], skipped: false)
    end

    def summary(spec, user_id, skipped:)
      { "name" => spec[:name], "slug" => Domain::Organizations::Text.slugify(spec[:name]), "owner" => spec[:owner].last,
        "owner_id" => user_id, "skipped" => skipped }
    end

    def confirm_owner(user_id)
      @system.uow.anonymous { |tx| @system.repos[:users].confirm_email(tx, user_id, @system.clock.now) }
    end

    # Convites aceitos diretamente com token conhecido (somente no seed local).
    def add_member(actor, name, email, role)
      token = invite_with_known_token(actor, email, role)
      uc(:accept_invitation).call(token: token, name: name, password: PASSWORD)
    end

    def invite_with_known_token(actor, email, role)
      invitation = uc(:invite_member).call(actor, email: email, role: role)
      token = "#{actor.organization_id}.seed-#{@system.ids.token(24)}"
      @system.uow.run(actor) do |tx, _|
        tx.execute("UPDATE invitations SET token_digest = $1 WHERE id = $2", [Application::Identity::Tokens.digest(token), invitation["id"]])
      end
      token
    end

    def seed_catalog(actor, branch, spec)
      products = {}
      spec[:serialized].each do |sku, name, count, pricing, deposit|
        product = uc(:create_product).call(actor, { sku: sku, name: name, tracking: "serialized", pricing: pricing, buffer_after_minutes: 60,
                                                    deposit: D::Money.new(deposit), replacement_cost: D::Money.new(deposit * 4) })
        count.times do |i|
          uc(:register_asset).call(actor, { product_id: product.id, branch_id: branch.id, tag: "#{sku}-#{format("%03d", i + 1)}",
                                            serial_number: "SN#{sku.delete("-")}#{i + 1}", acquisition_cost: D::Money.new(deposit * 3) })
        end
        products[sku] = product
      end
      spec[:bulk].each do |sku, name, quantity, pricing|
        product = uc(:create_product).call(actor, { sku: sku, name: name, tracking: "bulk", pricing: pricing })
        uc(:adjust_stock).call(actor, product_id: product.id, branch_id: branch.id, quantity: quantity, kind: "acquisition", reason: "estoque inicial")
        products[sku] = product
      end
      sku, name, pricing, components = spec[:kit]
      kit = uc(:create_product).call(actor, { sku: sku, name: name, tracking: "kit", pricing: pricing })
      uc(:set_kit_components).call(actor, kit.id, components.map { |c_sku, qty| { product_id: products.fetch(c_sku).id, quantity: qty } })
      products.merge(sku => kit)
    end

    def seed_reservations(actor, branch, customers, products)
      zone = uc(:get_organization).call(actor)[:organization].time_zone
      today = zone.local_date(@system.clock.now)
      first = products.values.find(&:serialized?)
      bulk = products.values.find(&:bulk?)
      [[2, 3, "confirm", [first, 1]], [4, 6, "hold", [bulk, 4]], [7, 8, "request", [first, 1]]].each_with_index do |(from, to, mode, (product, qty)), i|
        period = D::Period.new(zone.local_to_utc((today + from).year, (today + from).month, (today + from).day, 9),
                               zone.local_to_utc((today + to).year, (today + to).month, (today + to).day, 18))
        uc(:create_reservation).call(actor, { customer_id: customers[i % customers.size].id, branch_id: branch.id, period: period, mode: mode,
                                              lines: [D::Reservations::Line.new(product_id: product.id, quantity: qty)], hold_minutes: 1440 })
      end
    end
  end
end
