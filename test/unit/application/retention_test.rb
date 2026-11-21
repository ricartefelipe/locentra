# frozen_string_literal: true

require_relative "../unit_helper"

# Retenção do histórico de integrações com portas falsas: ordem entregas → outbox → recebidos, lotes
# até o primeiro incompleto ou até o teto, corte por tipo calculado do relógio, totais só com remoção e
# cada lote numa transação própria no contexto da organização.
class RetentionPurgeHistoryTest < UnitTest
  A = Locentra::Application
  NOW = Time.utc(2026, 6, 1, 3)
  DAY = 86_400

  class FakeRetention
    attr_reader :calls

    # `plan`: método → lista de quantidades devolvidas em sequência (0 quando esgota).
    def initialize(plan = {})
      @plan = plan.transform_values(&:dup)
      @calls = []
    end

    A::Retention::STEPS.map(&:last).each do |name|
      define_method(name) do |tx, before:, limit:|
        @calls << [name, tx, before, limit]
        Array(@plan[name]).shift || 0
      end
    end
  end

  class FakeTransactor
    attr_reader :tenants

    def initialize = @tenants = []

    def call(tenant_id:)
      @tenants << tenant_id
      yield "tx-#{@tenants.size}"
    end
  end

  class FakeTotals
    attr_reader :entries

    def initialize = @entries = []
    def add(tx, *args) = @entries << [tx, *args]
  end

  Clock = Struct.new(:now)

  def purge(plan = {}, batch_size: 3, max_batches: 4)
    @retention = FakeRetention.new(plan)
    @transactor = FakeTransactor.new
    @totals = FakeTotals.new
    windows = A::Retention::Windows.new(outbox_seconds: 30 * DAY, deliveries_seconds: 7 * DAY, inbound_seconds: 90 * DAY)
    A::Retention::PurgeHistory.new(transactor: @transactor, retention: @retention, totals: @totals, clock: Clock.new(NOW), windows: windows,
                                   batch_size: batch_size, max_batches: max_batches).call("org-1")
  end

  def test_order_is_deliveries_then_outbox_then_inbound_with_the_cut_of_each_kind
    assert_equal({ "webhook_deliveries" => 0, "outbox_events" => 0, "inbound_webhooks" => 0 }, purge)
    assert_equal %i[purge_finished_deliveries purge_disabled_endpoint_deliveries purge_dispatched_events purge_processed_inbound],
                 @retention.calls.map(&:first)
    assert_equal([NOW - (7 * DAY), NOW - (7 * DAY), NOW - (30 * DAY), NOW - (90 * DAY)], @retention.calls.map { |call| call[2] })
    assert(@retention.calls.all? { |call| call[3] == 3 })
  end

  def test_each_step_stops_at_the_first_partial_batch
    result = purge({ purge_finished_deliveries: [3, 3, 1], purge_dispatched_events: [2], purge_processed_inbound: [3, 0] })

    assert_equal({ "webhook_deliveries" => 7, "outbox_events" => 2, "inbound_webhooks" => 3 }, result)
    assert_equal({ purge_finished_deliveries: 3, purge_disabled_endpoint_deliveries: 1, purge_dispatched_events: 1, purge_processed_inbound: 2 },
                 @retention.calls.map(&:first).tally)
  end

  def test_each_step_is_capped_by_max_batches
    result = purge({ purge_disabled_endpoint_deliveries: [3] * 10 }, max_batches: 4)

    assert_equal 12, result["webhook_deliveries"]
    assert_equal(4, @retention.calls.count { |call| call.first == :purge_disabled_endpoint_deliveries })
  end

  def test_totals_only_for_positive_counts_in_the_transaction_of_the_batch
    purge({ purge_finished_deliveries: [3, 2], purge_processed_inbound: [1] })

    assert_equal [["tx-1", "retention", "webhook_deliveries", 3, NOW], ["tx-2", "retention", "webhook_deliveries", 2, NOW],
                  ["tx-5", "retention", "inbound_webhooks", 1, NOW]], @totals.entries
  end

  def test_every_batch_runs_in_its_own_transaction_of_the_organization
    purge({ purge_finished_deliveries: [3, 3, 0] })

    assert_equal ["org-1"] * 6, @transactor.tenants
    assert_equal(%w[tx-1 tx-2 tx-3 tx-4 tx-5 tx-6], @retention.calls.map { |call| call[1] })
  end
end
