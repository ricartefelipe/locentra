# frozen_string_literal: true

require_relative "repository_helper"
require_relative "../support/commercial_terms_support"

# Repositórios de cupons e do livro de usos com o papel de aplicação real: busca, situação calculada
# na SQL (igual à do domínio), contagem de usos ativos depois da trava e gatilho de limite.
class CommercialTermsRepositoryTest < DatabaseTest
  include CommercialTermsSupport
  include PropertyTesting

  def setup
    super
    @org = create_organization
    @actor = @org[:actor]
    @branch = @org[:branch]
    @customer = create_customer(@actor)
    @chairs = create_product(@actor, sku: "CAD-CUPOM", tracking: "bulk", pricing: { "daily_cents" => 10_000 })
    stock(@actor, @chairs, @branch, 50)
    @coupons = @system.repos[:coupons]
    @pricing = @system.repos[:pricing]
  end

  def window(day = 10) = period(format("2026-03-%02dT08:00:00Z", day), format("2026-03-%02dT08:00:00Z", day + 1))
  def book(mode: "confirm", day: 10, **) = reserve(@actor, @customer, @branch, window(day), [line(@chairs, 1)], mode: mode, **)

  def search(status: nil, search: "", sort: "code", limit: 100, offset: 0, now: @clock.now)
    tenant_tx { |tx| @coupons.search(tx, status: status, search: search, sort: sort, limit: limit, offset: offset, now: now) }
  end

  def codes(**) = search(**).first.map { |coupon, _status| coupon.code }

  def redemption_row(coupon, reservation, at: @clock.now)
    { "id" => SecureRandom.uuid, "coupon_id" => coupon.id, "reservation_id" => reservation.id, "subtotal_cents" => 10_000,
      "discount_cents" => 1_000, "redeemed_by" => @org[:user_id], "redeemed_at" => at }
  end

  def redeem(coupon, reservation, at: @clock.now) = tenant_tx { |tx| @pricing.insert_redemption(tx, redemption_row(coupon, reservation, at: at)) }

  def test_search_filters_by_the_status_computed_at_the_given_instant
    create_coupon("VIGENTE")
    create_coupon("AGENDADO", valid_from: @clock.now + 86_400)
    create_coupon("EXPIRA", valid_until: @clock.now + 3_600)
    create_coupon("ESGOTADO", max_redemptions: 1)
    uc(:set_coupon_active).call(@actor, create_coupon("DESATIVADO").id, active: false)
    book(coupon_code: "ESGOTADO")

    assert_equal %w[AGENDADO DESATIVADO ESGOTADO EXPIRA VIGENTE], codes
    assert_equal %w[EXPIRA VIGENTE], codes(status: "active")
    @clock.advance(3_600)
    expected = { "active" => %w[VIGENTE], "scheduled" => %w[AGENDADO], "expired" => %w[EXPIRA], "exhausted" => %w[ESGOTADO],
                 "inactive" => %w[DESATIVADO] }

    expected.each { |status, found| assert_equal found, codes(status: status), status }
    rows, total = search(status: "exhausted")

    assert_equal 1, total
    assert_equal ["exhausted", 1, 1, "1 de 1"], [rows.first.last, rows.first.first.redemptions, rows.first.first.total_redemptions,
                                                 rows.first.first.usage_text]
    assert_equal %w[AGENDADO], codes(status: "scheduled", now: @clock.now + 82_799), "início exclusivo até o instante da vigência"
    assert_equal %w[AGENDADO VIGENTE], codes(status: "active", now: @clock.now + 82_800)
  end

  def test_search_escapes_wildcards_and_matches_code_prefix_or_description
    create_coupon("A_B10", description: "Desconto de 100% no frete")
    create_coupon("AXB10", description: "Desconto de 1000 pontos")
    create_coupon("PROMO_A", description: "Campanha de verão")

    assert_equal %w[A_B10], codes(search: "a_"), "sublinhado é literal e a busca por código é por prefixo"
    assert_equal %w[A_B10], codes(search: "100%"), "percentual é literal na descrição"
    assert_equal %w[A_B10], codes(search: "%")
    assert_equal %w[AXB10 A_B10], codes(search: "DESCONTO DE 100").sort
    assert_equal %w[PROMO_A], codes(search: "promo")
    assert_equal %w[PROMO_A], codes(search: "de verão")
    assert_empty codes(search: "B10"), "o código não é buscado pelo meio"
    assert_empty codes(search: "\\")
    assert_equal 3, search.last
  end

  def test_search_sorts_by_allowlist_and_paginates
    create_coupon("CCC", valid_until: @clock.now + 3_600)
    @clock.advance(60)
    create_coupon("AAA")
    @clock.advance(60)
    create_coupon("BBB", valid_until: @clock.now + 600)

    assert_equal %w[AAA BBB CCC], codes(sort: "code")
    assert_equal %w[BBB AAA CCC], codes(sort: "-created_at")
    assert_equal %w[BBB CCC AAA], codes(sort: "valid_until"), "sem prazo por último"
    rows, total = search(limit: 2, offset: 2)

    assert_equal [%w[CCC], 3], [rows.map { |coupon, _| coupon.code }, total]
    assert_equal [[], 3], search(limit: 2, offset: 4)
    assert_raises(D::ValidationError) { search(sort: "value; DROP TABLE coupons") }
  end

  def test_repeated_code_inserts_nothing_and_other_organizations_are_independent
    coupon = create_coupon("REPETIDO")
    copy = coupon.with(id: SecureRandom.uuid, value: 2_000)

    assert_equal(0, tenant_tx { |tx| @coupons.insert(tx, copy) })
    other = create_organization(name: "Locadora Beta", email: "beta@example.test")

    assert_equal 1, tenant_tx(other) { |tx| @coupons.insert(tx, copy) }
    assert_equal 1_000, tenant_tx { |tx| @coupons.find_by_code(tx, "REPETIDO", now: @clock.now) }.value
    assert_equal 2_000, tenant_tx(other) { |tx| @coupons.find_by_code(tx, "REPETIDO", now: @clock.now) }.value
    assert_nil tenant_tx(other) { |tx| @coupons.find(tx, coupon.id, now: @clock.now) }, "identificador de outra organização"
    fee = create_fee("ENTREGA", "Entrega", 15_000)

    assert_equal(0, tenant_tx { |tx| @system.repos[:fees].insert(tx, fee.with(id: SecureRandom.uuid)) })
    assert_equal 1, tenant_tx(other) { |tx| @system.repos[:fees].insert(tx, fee.with(id: SecureRandom.uuid)) }
  end

  def test_optimistic_update_writes_only_the_expected_version
    coupon = create_coupon("VERSAO")
    revised = Pricing::Coupons.revise(coupon, { description: "Primeira" }, now: @clock.now)

    assert_equal(1, tenant_tx { |tx| @coupons.update(tx, revised, 1) })
    assert_equal(0, tenant_tx { |tx| @coupons.update(tx, revised.with(description: "Perdida"), 1) })
    stored = tenant_tx { |tx| @coupons.find(tx, coupon.id, now: @clock.now) }

    assert_equal ["Primeira", 2, 0, 0], [stored.description, stored.lock_version, stored.redemptions, stored.total_redemptions]
    assert_equal("Dona Locadora Alfa", tenant_tx { |tx| @coupons.actor_name(tx, stored.created_by) })
    assert_nil(tenant_tx { |tx| @coupons.actor_name(tx, nil) })
  end

  # Em READ COMMITTED, a contagem na mesma instrução do FOR UPDATE usaria o snapshot anterior à espera
  # pela trava. O uso gravado pela transação que detinha a trava precisa aparecer para a seguinte.
  def test_locked_coupon_lookup_counts_uses_after_acquiring_the_lock
    coupon = create_coupon("TRAVA", max_redemptions: 5)
    reservation = book(mode: "request")
    waiting = nil
    tenant_tx do |tx|
      assert_equal 0, @pricing.find_coupon(tx, "TRAVA", lock: true, now: @clock.now).redemptions
      waiting = Thread.new { tenant_tx { |other| @pricing.find_coupon(other, "TRAVA", lock: true, now: @clock.now).redemptions } }
      wait_for_lock_queue
      @pricing.insert_redemption(tx, redemption_row(coupon, reservation))
    end

    assert_equal 1, waiting.value, "a segunda transação vê o uso confirmado pela primeira"
    assert_equal 1, tenant_tx { |tx| @coupons.lock(tx, coupon.id, now: @clock.now) }.redemptions
    assert_equal(1, tenant_tx { |tx| @pricing.active_redemptions(tx, coupon.id, @clock.now) })
    assert_nil(tenant_tx { |tx| @pricing.find_coupon(tx, "OUTRO", lock: true, now: @clock.now) })
  end

  # Espera até outra conexão do papel da aplicação ficar bloqueada aguardando a trava do cupom.
  def wait_for_lock_queue
    conn = PG.connect(TestDatabase.app_url)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until conn.exec("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'").getvalue(0, 0).to_i.positive?
      raise "a segunda transação não chegou à fila da trava" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  ensure
    conn&.close
  end

  def test_limit_trigger_refuses_uses_beyond_the_maximum
    coupon = create_coupon("LIMITE", max_redemptions: 3)
    first, second, third, fourth = Array.new(4) { |i| book(mode: "request", day: 10 + i) }
    redeem(coupon, first)
    redeem(coupon, second)
    duplicate = conflict_code { redeem(coupon, first) }

    assert_equal "duplicate:coupon_redemptions_organization_id_reservation_id_key", duplicate, "um uso por reserva"
    redeem(coupon, third)

    assert_equal({ "base" => ["dados inválidos"] }, error_fields { redeem(coupon, fourth) })
    uc(:cancel_reservation).call(@actor, first.id, reason: "Cliente desistiu")
    redeem(coupon, fourth)
    stored = tenant_tx { |tx| @coupons.find(tx, coupon.id, now: @clock.now) }

    assert_equal [3, 4, "exhausted"], [stored.redemptions, stored.total_redemptions, stored.status(@clock.now)]
    unlimited = create_coupon("LIVRE")
    4.times { |i| redeem(unlimited, book(mode: "request", day: 15 + i)) }

    assert_equal "4 (sem limite)", usage("LIVRE")
  end

  # O instante de referência do gatilho é o do próprio uso (relógio da aplicação), recuado pela carência
  # do limite: um bloqueio temporário vencido e ainda não varrido deixa de contar depois da carência.
  def test_limit_trigger_ignores_expired_holds_after_the_grace_at_the_redemption_instant
    coupon = create_coupon("BLOQUEIO", max_redemptions: 1)
    hold = book(mode: "hold", hold_minutes: 10)
    redeem(coupon, hold)
    other = book(mode: "request", day: 12)
    grace = Pricing::Redemptions::LIMIT_GRACE

    assert_raises(D::ValidationError) { redeem(coupon, other, at: @clock.now + 599) }
    assert_raises(D::ValidationError) { redeem(coupon, other, at: @clock.now + 600 + grace - 1) }
    redeem(coupon, other, at: @clock.now + 600 + grace)

    assert_equal "held", status_of(hold), "o bloqueio continua sem varredura"
    assert_equal(2, tenant_tx { |tx| @pricing.active_redemptions(tx, coupon.id, @clock.now) })
    assert_equal(1, tenant_tx { |tx| @pricing.active_redemptions(tx, coupon.id, @clock.now + 600) })
    unused = create_coupon("NUNCA")

    assert_equal([true, false], tenant_tx { |tx| [coupon, unused].map { |c| @coupons.ever_redeemed?(tx, c.id) } })
  end

  def test_redemption_listing_respects_actor_scopes_and_orders_by_instant
    coupon = create_coupon("LISTA")
    first = book(coupon_code: "LISTA")
    @clock.advance(60)
    second = book(coupon_code: "LISTA", day: 12)
    list = lambda do |names, refs, limit: 10, offset: 0|
      tenant_tx do |tx|
        @coupons.redemptions(tx, coupon.id, limit: limit, offset: offset, now: @clock.now, customer_names: names, reservation_refs: refs)
      end
    end
    rows, total = list.call(true, true)

    assert_equal [2, [second.id, first.id]], [total, rows.map { |row| row["reservation_id"] }]
    assert_equal [second.code, "Cliente Teste", "confirmed", true],
                 rows.first.values_at("reservation_code", "customer_name", "reservation_status", "active")
    assert_equal([[nil, nil]], list.call(false, false, limit: 1).first.map { |row| row.values_at("reservation_code", "customer_name") })
    assert_equal([first.id], list.call(true, true, limit: 1, offset: 1).first.map { |row| row["reservation_id"] })
  end

  # Dados aleatórios, instante aleatório: a situação calculada na SQL é a do domínio, e os usos ativos
  # da SQL (listagem, contagem e coluna `active`) seguem Redemptions.active?.
  def test_property_sql_status_and_active_uses_match_the_domain
    base = @clock.now
    uses = random_uses(Random.new(Integer(ENV.fetch("SEED", Minitest.seed.to_s))), base)
    property("situação e usos ativos na SQL", runs: 25) do |generator|
      at = base + generator.rand(-9_000..9_000)
      rows, total = search(now: at)

      assert_equal uses.size, total
      rows.each do |coupon, status|
        active = uses.fetch(coupon.id).count { |state, hold, _id| Pricing::Redemptions.active?(state, hold, at) }

        assert_equal coupon.legacy_redemptions + active, coupon.redemptions, coupon.code
        assert_equal coupon.legacy_redemptions + uses.fetch(coupon.id).size, coupon.total_redemptions
        assert_equal coupon.status(at), status, coupon.code
        assert_equal(active, tenant_tx { |tx| @pricing.active_redemptions(tx, coupon.id, at) })
        assert_includes codes(status: status, now: at), coupon.code
      end
      listed = rows.flat_map { |coupon, _| listed_uses(coupon, at) }

      assert(listed.all? { |row| row["active"] == Pricing::Redemptions.active?(row["reservation_status"], row["hold_expires_at"], at) })
    end
  end

  # Usos aleatórios por cupom: { coupon_id => [[situação da reserva, fim do bloqueio, reserva]] }. Os usos
  # são gravados com as reservas canceladas (nenhum uso ativo), para que o gatilho de limite não recuse a
  # montagem do cenário; a situação aleatória de cada reserva é aplicada em seguida.
  def random_uses(random, base)
    reservations = Array.new(24) { |i| book(mode: "request", day: 5 + (i % 20)) }
    coupons = random_coupons(random, base)
    uses = coupons.to_h { |coupon| [coupon["id"], []] }
    open_ids = coupons.reject { |coupon| coupon["full"] }.map { |coupon| coupon["id"] }
    owner_query("UPDATE reservations SET status = 'cancelled'")
    reservations.each do |reservation|
      coupon_id = open_ids.sample(random: random)
      owner_query(<<~SQL, [SecureRandom.uuid, @org[:organization_id], coupon_id, reservation.id, base])
        INSERT INTO coupon_redemptions (id, organization_id, coupon_id, reservation_id, subtotal_cents, discount_cents, redeemed_at)
        VALUES ($1, $2, $3, $4, 1000, 100, $5)
      SQL
      uses[coupon_id] << random_state(random, base, reservation)
    end
    uses.each_value do |list|
      list.each { |status, hold, id| owner_query("UPDATE reservations SET status = $2, hold_expires_at = $3 WHERE id = $1", [id, status, hold]) }
    end
    uses
  end

  def random_state(random, base, reservation)
    status = D::Reservations::STATUSES.keys.sample(random: random)
    hold = base + random.rand(-7_200..7_200) if status == "held" || random.rand(3).zero?
    [status, hold, reservation.id]
  end

  def listed_uses(coupon, at)
    tenant_tx do |tx|
      @coupons.redemptions(tx, coupon.id, limit: 100, offset: 0, now: at, customer_names: false, reservation_refs: false).first
    end
  end

  # Cupons gravados pelo proprietário do esquema, sem o gatilho de limite no caminho: contador legado,
  # vigências e situação variados em torno do instante base.
  def random_coupons(random, base)
    Array.new(12) do |i|
      max = random.rand(3).zero? ? nil : random.rand(1..4)
      from = random.rand(2).zero? ? nil : base + random.rand(-7_200..3_600)
      to = random.rand(2).zero? ? nil : (from || base) + random.rand(1..7_200)
      legacy = max ? random.rand(0..max) : random.rand(0..3)
      row = { "id" => SecureRandom.uuid, "code" => "PROP#{i}", "full" => !max.nil? && legacy >= max }
      owner_query(<<~SQL, [row["id"], @org[:organization_id], row["code"], from, to, max, legacy, random.rand(4).positive?, base])
        INSERT INTO coupons (id, organization_id, code, kind, value, valid_from, valid_until, max_redemptions, redemptions, active, created_at, updated_at)
        VALUES ($1, $2, $3, 'percent', 1000, $4, $5, $6, $7, $8, $9, $9)
      SQL
      row
    end
  end
end
