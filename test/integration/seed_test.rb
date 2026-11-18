# frozen_string_literal: true

require_relative "integration_helper"
require "locentra/seed"

# Seed da demonstração: duas organizações e o preparo do roteiro manual, idempotentes.
class SeedTest < DatabaseTest
  def user_id(email) = @system.uow.anonymous { |tx| @system.repos[:users].find_by_email(tx, email) }["id"]
  def memberships(email) = uc(:list_memberships).call(user_id(email)).map { |m| [m["name"], m["role"]] }
  def organization_id(owner, name) = uc(:list_memberships).call(user_id(owner)).find { |m| m["name"] == name }["organization_id"]

  def simulator_accounts
    owner_query("SELECT count(*) AS n FROM payment_provider_accounts WHERE provider = 'simulator' AND active",
                tenant: organization_id("ana@alfa.demo", "Alfa Audiovisual")).first["n"].to_i
  end

  def users = owner_query("SELECT count(*) AS n FROM users").first["n"].to_i

  def test_seed_prepares_the_demonstration_and_is_idempotent
    first = Locentra::Seed.new(@system).run

    assert_equal([false, false], first.map { |org| org["skipped"] })
    assert_equal [["Alfa Audiovisual", "owner"], ["Beta Eventos", "manager"]], memberships("ana@alfa.demo")
    assert_equal 1, simulator_accounts
    before = users
    second = Locentra::Seed.new(@system).run

    assert_equal([true, true], second.map { |org| org["skipped"] })
    assert_equal 2, memberships("ana@alfa.demo").size
    assert_equal 1, simulator_accounts
    assert_equal before, users
  end

  def test_demonstration_access_is_completed_on_databases_seeded_before
    Locentra::Seed.new(@system).run
    beta = organization_id("paulo@beta.demo", "Beta Eventos")
    owner_query("UPDATE payment_provider_accounts SET active = false, deactivated_at = now()", tenant: organization_id("ana@alfa.demo", "Alfa Audiovisual"))
    owner_query("UPDATE memberships SET status = 'revoked', revoked_at = now() WHERE user_id = $1", [user_id("ana@alfa.demo")], tenant: beta)

    assert_equal 1, memberships("ana@alfa.demo").size
    assert_equal 0, simulator_accounts
    Locentra::Seed.new(@system).run

    assert_equal [["Alfa Audiovisual", "owner"], ["Beta Eventos", "manager"]], memberships("ana@alfa.demo")
    assert_equal 1, simulator_accounts
  end
end
