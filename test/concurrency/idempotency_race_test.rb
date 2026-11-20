# frozen_string_literal: true

require_relative "concurrency_helper"

# Duas requisições simultâneas com a mesma Idempotency-Key: a segunda espera no índice único enquanto a
# primeira está em andamento e então recebe o resultado gravado (sem efeito duplicado), recusa conteúdo
# diferente ou, se a primeira falhou, executa a operação.
class IdempotencyRaceTest < DatabaseTest
  KEY = "pedido-concorrente-0001"

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @customer = create_customer(@actor)
    @camera = create_product(@actor, sku: "CAM-IDEM", tracking: "serialized")
    register_assets(@actor, @camera, @org[:branch], 2)
    @input = { customer_id: @customer.id, branch_id: @org[:branch].id, period: period("2026-03-10T08:00:00Z", "2026-03-10T12:00:00Z"),
               lines: [line(@camera, 1)], mode: "confirm" }
  end

  def idempotent(fingerprint, &)
    uc(:idempotency).call(@actor, permission: "reservations.write", scope: "POST /api/v1/reservations", key: KEY, fingerprint: fingerprint, &)
  end

  def create(tx, actor)
    reservation = uc(:create_reservation).call(actor, @input, tx: tx)
    [201, { "id" => reservation.id }]
  end

  # Espera até outra conexão do papel da aplicação ficar bloqueada aguardando lock (o INSERT da chave).
  def wait_for_blocked_backend
    conn = PG.connect(TestDatabase.app_url)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until conn.exec("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'").getvalue(0, 0).to_i.positive?
      raise "nenhuma requisição concorrente aguardando a chave" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  ensure
    conn&.close
  end

  # A primeira requisição reserva a chave e só termina depois que a segunda está aguardando no índice.
  def race(first:, second_fingerprint:)
    claimed = Queue.new
    one = Thread.new do
      idempotent("mesmo-corpo") do |tx, actor|
        claimed << true
        wait_for_blocked_backend
        first.call(tx, actor)
      end
    rescue StandardError => e
      e
    end
    claimed.pop
    two = Thread.new do
      idempotent(second_fingerprint) { |tx, actor| create(tx, actor) }
    rescue StandardError => e
      e
    end
    [one.value, two.value]
  end

  def reservations = owner_query("SELECT count(*) AS n FROM reservations").first["n"].to_i

  def test_concurrent_equivalent_request_waits_and_receives_the_stored_result
    first, second = race(first: method(:create), second_fingerprint: "mesmo-corpo")

    assert_equal [false, true], [first.replayed, second.replayed]
    assert_equal first.body, second.body
    assert_equal [201, 201], [first.status, second.status]
    assert_equal 1, reservations, "uma única reserva"
  end

  def test_concurrent_request_with_different_content_is_refused
    first, second = race(first: method(:create), second_fingerprint: "outro-corpo")

    refute first.replayed
    assert_kind_of D::Conflict, second
    assert_equal "idempotency_key_reused", second.code
    assert_equal 1, reservations
  end

  def test_when_the_first_request_fails_the_waiting_one_executes
    failing = ->(_tx, _actor) { raise D::ValidationError.field("items", "falha na primeira requisição") }
    first, second = race(first: failing, second_fingerprint: "mesmo-corpo")

    assert_kind_of D::ValidationError, first
    refute second.replayed, "a chave não foi gravada pela falha"
    assert_equal 1, reservations
  end
end
