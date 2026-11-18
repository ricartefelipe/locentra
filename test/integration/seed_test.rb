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
end
