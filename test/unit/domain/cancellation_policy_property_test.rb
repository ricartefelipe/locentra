# frozen_string_literal: true

require_relative "../unit_helper"

# Propriedades da política de cancelamento com listas aleatórias de faixas (inclusive fora dos limites):
# invariantes da forma canônica, equivalência com um verificador de referência, idempotência, invariância
# a permutações, multa da faixa aplicável e uma linha de descrição por faixa.
class CancellationPolicyPropertyTest < UnitTest
  P = Domain::Organizations::CancellationPolicy

  def random_tiers(random)
    Array.new(random.rand(0..8)) { { "min_hours_before" => random.rand(-5..9000), "fee_bps" => random.rand(-100..10_100) } }
  end

  # Tiers que tendem a ser válidos: horas distintas com 0, multas não decrescentes quando as horas caem.
  def plausible_tiers(random)
    hours = ([0] + Array.new(random.rand(0..5)) { random.rand(1..8760) }).uniq.sort.reverse
    fee = 0
    hours.map { |hour| { "min_hours_before" => hour, "fee_bps" => fee = [fee + random.rand(0..4000), 10_000].min } }.shuffle(random: random)
  end

  # Verificador de referência, escrito sem reaproveitar o domínio.
  def reference_valid?(tiers)
    return false unless tiers.size.between?(1, 6)
    return false unless tiers.all? { |t| t["min_hours_before"].between?(0, 8760) && t["fee_bps"].between?(0, 10_000) }

    hours = tiers.map { |t| t["min_hours_before"] }
    return false unless hours.uniq.size == hours.size && hours.include?(0)

    fees = tiers.sort_by { |t| -t["min_hours_before"] }.map { |t| t["fee_bps"] }
    fees.each_cons(2).all? { |earlier, later| later >= earlier }
  end

  def built(tiers)
    P.build(tiers)
  rescue Domain::ValidationError
    nil
  end

  def test_build_either_raises_or_returns_a_policy_with_the_invariants
    property("invariantes da forma canônica") do |random|
      tiers = random.rand < 0.5 ? random_tiers(random) : plausible_tiers(random)
      result = built(tiers)

      assert_equal reference_valid?(tiers), !result.nil?, "aceita se e somente se cumpre as regras: #{tiers.inspect}"
      next unless result

      list = result["tiers"]
      hours = list.map { |t| t["min_hours_before"] }

      assert list.size.between?(1, 6)
      assert_equal hours.sort.reverse.uniq, hours, "ordem estritamente decrescente"
      assert_equal 0, hours.last
      assert(list.all? { |t| t["fee_bps"].is_a?(Integer) && t["fee_bps"].between?(0, 10_000) })
      assert(list.each_cons(2).all? { |earlier, later| later["fee_bps"] >= earlier["fee_bps"] })
      assert_equal result, P.build(result["tiers"]), "idempotente"
      assert_equal result, P.build(tiers.shuffle(random: random)), "invariante a permutações"
      assert_equal list.size, P.describe(result).size, "uma linha de descrição por faixa"
    end
  end

  def test_fee_is_the_one_of_the_largest_applicable_tier_and_is_monotonic
    starts_at = Time.utc(2026, 6, 1, 12)
    property("multa da faixa aplicável") do |random|
      result = built(plausible_tiers(random))
      next unless result

      instants = Array.new(6) { starts_at - random.rand((-200 * 3600)..(9000 * 3600)) }.sort
      fees = instants.map do |now|
        hours = Rational(starts_at.to_i - now.to_i, 3600)
        expected = result["tiers"].select { |t| t["min_hours_before"] <= hours }.max_by { |t| t["min_hours_before"] }
        expected ||= result["tiers"].find { |t| t["min_hours_before"].zero? }
        fee = P.fee_bps(result, starts_at: starts_at, now: now)

        assert_equal expected["fee_bps"], fee, "horas antes do início: #{hours.to_f}"
        fee
      end

      assert_equal fees.sort, fees, "a multa não diminui à medida que o início se aproxima"
    end
  end
end
