# frozen_string_literal: true

require_relative "integration_helper"
require "locentra/seed"

# Seed da demonstração: duas organizações e o preparo do roteiro manual, idempotentes e sem desfazer
# o que foi alterado no ambiente depois do seed.
class SeedTest < DatabaseTest
  def user_id(email) = @system.uow.anonymous { |tx| @system.repos[:users].find_by_email(tx, email) }["id"]
  def memberships(email) = uc(:list_memberships).call(user_id(email)).map { |m| [m["name"], m["role"]] }
  def organization_id(owner, name) = uc(:list_memberships).call(user_id(owner)).find { |m| m["name"] == name }["organization_id"]
  def alfa = organization_id("ana@alfa.demo", "Alfa Audiovisual")
  def beta = organization_id("paulo@beta.demo", "Beta Eventos")
  def owner(email, organization_id) = A::Actor.user(user_id: user_id(email), organization_id: organization_id, role: "owner")

  def active_accounts
    owner_query("SELECT provider FROM payment_provider_accounts WHERE active ORDER BY provider", tenant: alfa).map { |row| row["provider"] }
  end

  def users = owner_query("SELECT count(*) AS n FROM users").first["n"].to_i

  def test_seed_prepares_the_demonstration_and_is_idempotent
    first = Locentra::Seed.new(@system).run

    assert_equal([false, false], first.map { |org| org["skipped"] })
    assert_equal [["Alfa Audiovisual", "owner"], ["Beta Eventos", "manager"]], memberships("ana@alfa.demo")
    assert_equal ["simulator"], active_accounts
    before = users
    second = Locentra::Seed.new(@system).run

    assert_equal([true, true], second.map { |org| org["skipped"] })
    assert_equal 2, memberships("ana@alfa.demo").size
    assert_equal ["simulator"], active_accounts
    assert_equal before, users
  end

  # Banco semeado antes do preparo da demonstração: sem o vínculo da Ana com a Beta e sem conta de
  # provedor na Alfa (as linhas são removidas pelo papel proprietário, como se nunca tivessem existido).
  def test_demonstration_access_is_completed_on_databases_seeded_before
    Locentra::Seed.new(@system).run
    owner_query("DELETE FROM payment_provider_accounts", tenant: alfa)
    owner_query("DELETE FROM memberships WHERE user_id = $1", [user_id("ana@alfa.demo")], tenant: beta)

    assert_equal 1, memberships("ana@alfa.demo").size
    assert_empty active_accounts
    Locentra::Seed.new(@system).run

    assert_equal [["Alfa Audiovisual", "owner"], ["Beta Eventos", "manager"]], memberships("ana@alfa.demo")
    assert_equal ["simulator"], active_accounts
  end

  # Repetir o seed (por exemplo, pelo bin/setup) não troca o provedor configurado pelo desenvolvedor,
  # não reativa uma conta desativada e não devolve um acesso revogado de propósito.
  def test_reseeding_keeps_later_changes_to_accounts_and_memberships
    Locentra::Seed.new(@system).run
    ana = owner("ana@alfa.demo", alfa)
    uc(:configure_payment_account).call(ana, provider: "asaas", name: "Asaas sandbox", api_key: "$aact_hmlg_chave-de-teste-1234")
    paulo = owner("paulo@beta.demo", beta)
    membership = uc(:list_members).call(paulo)[:members].find { |m| m["email"] == "ana@alfa.demo" }
    uc(:revoke_membership).call(paulo, membership_id: membership["id"])
    Locentra::Seed.new(@system).run

    assert_equal ["asaas"], active_accounts, "a conta Asaas continua ativa e o simulador não volta"
    assert_equal [["Alfa Audiovisual", "owner"]], memberships("ana@alfa.demo"), "o vínculo revogado não é recriado"
    uc(:deactivate_payment_account).call(ana, uc(:finance).accounts(ana).find { |a| a["active"] }["id"])
    Locentra::Seed.new(@system).run

    assert_empty active_accounts, "a organização ficou sem conta ativa por decisão de quem a desativou"
    assert_equal 2, owner_query("SELECT count(*) AS n FROM payment_provider_accounts", tenant: alfa).first["n"].to_i
  end

  def commercial_terms(organization_id)
    { coupons: owner_query("SELECT code FROM coupons ORDER BY code", tenant: organization_id).map { |row| row["code"] },
      fees: owner_query("SELECT code FROM additional_fees ORDER BY code", tenant: organization_id).map { |row| row["code"] },
      agreements: owner_query(<<~SQL, tenant: organization_id).map(&:values) }
        SELECT c.document, p.sku, a.discount_bps::text FROM customer_price_agreements a
          JOIN customers c ON c.id = a.customer_id LEFT JOIN products p ON p.id = a.product_id
         ORDER BY a.discount_bps
      SQL
  end

  # Condições comerciais do passo 15 do roteiro: criadas uma única vez, pelos casos de uso (auditadas).
  def test_seed_creates_the_commercial_terms_of_the_demonstration_once
    Locentra::Seed.new(@system).run
    expected = { coupons: %w[BEMVINDO10 PRIMEIRALOCACAO], fees: %w[ENTREGA LIMPEZA MONTAGEM],
                 agreements: [["11222333000181", nil, "800"], %w[52998224725 LEN-2470 1000]] }

    assert_equal expected, commercial_terms(alfa)
    assert_equal({ coupons: %w[PRIMAVERA15], fees: %w[ENTREGA MONTAGEM], agreements: [["45723174000110", nil, "500"]] }, commercial_terms(beta))
    ana = owner("ana@alfa.demo", alfa)
    welcome = uc(:get_coupon).call(ana, "BEMVINDO10")[:coupon]

    assert_equal ["percent", 1_000, "0 de 100", @clock.now + (365 * 86_400)], [welcome.kind, welcome.value, welcome.usage_text, welcome.valid_until]
    first = uc(:get_coupon).call(ana, "PRIMEIRALOCACAO")[:coupon]

    assert_equal [5_000, 30_000, 1], [first.value, first.min_subtotal_cents, first.max_redemptions]
    assert_equal "R$ 50,00 em locações a partir de R$ 300,00 (uso único)", first.description, "o mínimo é inclusivo"
    assert_equal 15_000, uc(:get_fee).call(ana, "ENTREGA")[:fee].default_amount.cents
    audited = owner_query(<<~SQL, tenant: alfa).map(&:values)
      SELECT action, count(*)::text AS n FROM audit_events
       WHERE action IN ('coupon.created', 'fee.created', 'price_agreement.created') GROUP BY action ORDER BY action
    SQL

    assert_equal [["coupon.created", "2"], ["fee.created", "3"], ["price_agreement.created", "2"]], audited
    Locentra::Seed.new(@system).run

    assert_equal expected, commercial_terms(alfa), "repetir o seed não duplica nada"
  end

  # Banco semeado antes das condições comerciais é completado; o que foi desativado, encerrado ou
  # alterado depois do seed não é reativado, recriado nem revertido.
  def test_commercial_terms_are_completed_without_undoing_later_changes
    Locentra::Seed.new(@system).run
    ana = owner("ana@alfa.demo", alfa)
    owner_query("DELETE FROM coupons WHERE code = 'PRIMEIRALOCACAO'", tenant: alfa)
    owner_query("DELETE FROM additional_fees WHERE code = 'LIMPEZA'", tenant: alfa)
    uc(:set_coupon_active).call(ana, "BEMVINDO10", active: false)
    uc(:set_fee_active).call(ana, "ENTREGA", active: false)
    uc(:update_fee).call(ana, "MONTAGEM", { default_amount: D::Money.new(30_000) })
    horizonte = uc(:list_customers).call(ana, search: "11222333000181").items.first
    agreement = uc(:list_price_agreements).call(ana, horizonte.id).items.first[:agreement]
    uc(:end_price_agreement).call(ana, agreement.id, reason: "Contrato encerrado")
    Locentra::Seed.new(@system).run

    assert_equal %w[BEMVINDO10 PRIMEIRALOCACAO], commercial_terms(alfa)[:coupons], "o cupom que faltava é criado"
    assert_equal %w[ENTREGA LIMPEZA MONTAGEM], commercial_terms(alfa)[:fees]
    refute uc(:get_coupon).call(ana, "BEMVINDO10")[:coupon].active, "cupom desativado depois do seed não é reativado"
    assert_equal [false, 30_000], [uc(:get_fee).call(ana, "ENTREGA")[:fee].active, uc(:get_fee).call(ana, "MONTAGEM")[:fee].default_amount.cents]
    conditions = uc(:list_price_agreements).call(ana, horizonte.id)

    assert_equal [1, "ended"], [conditions.total, conditions.items.first[:status]], "condição encerrada não é recriada"
  end
end
