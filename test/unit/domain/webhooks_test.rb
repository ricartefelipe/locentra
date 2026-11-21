# frozen_string_literal: true

require_relative "../unit_helper"

# Pausa automática do endpoint: exige ao menos 20 falhas consecutivas e ao menos 1 h desde a primeira.
class WebhooksCircuitTest < UnitTest
  Circuit = Domain::Webhooks::Circuit
  NOW = Time.utc(2026, 3, 2, 12)

  def trip?(failures, seconds_ago) = Circuit.trip?(consecutive_failures: failures, failing_since: seconds_ago && (NOW - seconds_ago), now: NOW)

  def test_pauses_only_with_enough_failures_and_enough_time
    refute trip?(19, 2 * 3600), "19 falhas em 2 h não pausam"
    refute trip?(20, 3599), "20 falhas em 59 min 59 s não pausam"
    assert trip?(20, 3600), "20 falhas com exatamente 1 h pausam"
    assert trip?(250, 3 * 3600)
    refute trip?(20, nil), "sem início da sequência não há pausa"
    refute trip?(0, nil)
  end
end
