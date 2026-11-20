# frozen_string_literal: true

require "delegate"
require_relative "concurrency_helper"
require_relative "../support/barrier"

# Conversões concorrentes do mesmo orçamento aprovado, em conexões separadas sincronizadas por barreira.
class QuoteConversionRaceTest < DatabaseTest
  Q = Locentra::Application::Quotes

  # Repositório que lê o orçamento sem FOR UPDATE: simula duas conversões que passam pela leitura ao
  # mesmo tempo, deixando somente o índice único parcial de reservations como proteção.
  class UnlockedQuotes < SimpleDelegator
    def lock(tx, id) = __getobj__.find(tx, id)
  end

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    customer = create_customer(@actor)
    camera = create_product(@actor, sku: "CAM-CONV", tracking: "serialized", pricing: { "daily_cents" => 8_000 })
    register_assets(@actor, camera, @branch, 2)
    @quote = uc(:create_quote).call(@actor, { customer_id: customer.id, branch_id: @branch.id, lines: [line(camera, 1)],
                                              period: period("2026-03-10T08:00:00Z", "2026-03-11T08:00:00Z"), valid_until: t("2026-03-06T00:00:00Z") })
    uc(:send_quote).call(@actor, @quote.id)
    uc(:approve_quote).call(@actor, @quote.id, version: 1, approver_name: "Comprador")
  end

  def convert_use_case(quotes)
    Q::ConvertQuote.new(uow: @system.uow, quotes: quotes, reservations: @system.repos[:reservations], create_reservation: uc(:create_reservation),
                        confirm_reservation: uc(:confirm_reservation), audit: @system.services[:audit], events: @system.services[:events],
                        clock: @clock)
  end

  def race(use_case)
    Array.new(2) { Thread.new { use_case.call(@actor, @quote.id) } }.map(&:value)
  end

  def reservations_for_quote
    owner_query("SELECT count(*) AS n FROM reservations WHERE quote_id = $1", [@quote.id]).first["n"].to_i
  end

  def test_concurrent_conversions_are_serialized_by_the_quote_lock
    barrier = Barrier.new(2)
    quotes = PausingProxy.new(@system.repos[:quotes], :lock, barrier)

    results = race(convert_use_case(quotes))

    assert_equal 1, results.map { |r| r.reservation.id }.uniq.size, "as duas conversões devolvem a mesma reserva"
    assert_equal([false, true], results.map(&:created).sort_by { |created| created ? 1 : 0 })
    assert_equal 1, reservations_for_quote
    assert_equal 1, owner_query("SELECT count(*) AS n FROM asset_allocations WHERE active").first["n"].to_i
    assert_equal "converted", uc(:get_quote).call(@actor, @quote.id)[:quote].status
  end

  def test_unique_index_returns_the_same_reservation_when_both_pass_the_read
    barrier = Barrier.new(2)
    quotes = PausingProxy.new(UnlockedQuotes.new(@system.repos[:quotes]), :lock, barrier, after: true)

    results = race(convert_use_case(quotes))

    assert_equal 1, results.map { |r| r.reservation.id }.uniq.size
    assert_equal([false, true], results.map(&:created).sort_by { |created| created ? 1 : 0 })
    assert_equal 1, reservations_for_quote
    assert_equal 1, owner_query("SELECT count(*) AS n FROM asset_allocations WHERE active").first["n"].to_i,
                 "a tentativa perdedora é desfeita e não aloca o segundo ativo"
    assert_equal 1, owner_query("SELECT count(*) AS n FROM audit_events WHERE action = 'quote.converted'").first["n"].to_i
  end

  def test_database_rejects_a_second_reservation_for_the_same_quote
    reservation = uc(:convert_quote).call(@actor, @quote.id).reservation
    conn = TestDatabase.owner_connection
    conn.exec("BEGIN")
    conn.exec_params("SELECT set_config('app.tenant_id', $1, true)", [@org[:organization_id]])

    assert_raises(PG::UniqueViolation) do
      conn.exec_params(<<~SQL, [SecureRandom.uuid, @org[:organization_id], @branch.id, reservation.customer_id, @quote.id])
        INSERT INTO reservations (id, organization_id, branch_id, customer_id, code, status, starts_at, ends_at, quote_id, created_at, updated_at)
        VALUES ($1, $2, $3, $4, 'R-DUP', 'requested', now() + interval '30 days', now() + interval '31 days', $5, now(), now())
      SQL
    end
  ensure
    conn&.exec("ROLLBACK")
  end
end
