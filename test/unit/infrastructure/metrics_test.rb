# frozen_string_literal: true

require_relative "../unit_helper"
require "stringio"
require "locentra/infrastructure/observability/logger"
require "locentra/interfaces/http/middleware"

# Registro de métricas e middleware de requisições: formato de exposição e cardinalidade dos rótulos.
class MetricsTest < UnitTest
  O = Locentra::Infrastructure::Observability

  # Uma amostra válida do formato texto do Prometheus: nome, rótulos opcionais e valor numérico.
  SAMPLE = /\A(?<name>[a-z_][a-z0-9_]*)(?:\{(?<labels>(?:[a-z_]+="(?:[^"\\\n]|\\.)*",?)*)\})? (?<value>-?\d+(?:\.\d+)?(?:e[+-]?\d+)?|\+Inf)\z/
  UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/

  def metrics = @metrics ||= O::Metrics.new

  def test_render_groups_each_family_under_help_and_type
    metrics.increment("http_requests_total", method: "GET", route: "/reservas/:id", status: "200")
    metrics.increment("http_requests_total", method: "POST", route: "/reservas", status: "409")
    metrics.gauge("jobs_queue_size", 3, queue: "default", status: "pending")
    metrics.observe("http_request_duration_seconds", 0.02, route: "/reservas")
    lines = metrics.render.lines(chomp: true)

    assert_equal "# HELP locentra_http_requests_total Requisições HTTP por método, rota modelo e status", lines[0]
    assert_equal "# TYPE locentra_http_requests_total counter", lines[1]
    assert_includes lines, 'locentra_http_requests_total{method="GET",route="/reservas/:id",status="200"} 1'
    assert_includes lines, "# TYPE locentra_jobs_queue_size gauge"
    assert_includes lines, "# TYPE locentra_http_request_duration_seconds histogram"
    families = lines.grep(/\A# TYPE /).map { |line| line.split[2] }

    assert_equal families.uniq, families, "cada família tem uma única linha TYPE"
    lines.grep_v(/\A#/).each { |line| assert_match SAMPLE, line }
  end

  def test_histogram_buckets_are_cumulative_and_end_with_inf
    [0.004, 0.2, 3.0].each { |value| metrics.observe("job_duration_seconds", value, kind: "events.dispatch") }
    lines = metrics.render.lines(chomp: true)
    bucket = ->(le) { lines.find { |l| l.start_with?(%(locentra_job_duration_seconds_bucket{kind="events.dispatch",le="#{le}"})) }.split.last.to_i }

    assert_equal 1, bucket.call("0.005")
    assert_equal 2, bucket.call("0.25")
    assert_equal 3, bucket.call("5")
    assert_equal 3, bucket.call("+Inf")
    assert_includes lines, 'locentra_job_duration_seconds_count{kind="events.dispatch"} 3'
    assert_includes lines, 'locentra_job_duration_seconds_sum{kind="events.dispatch"} 3.204'
  end

  def test_labels_outside_the_allowlist_are_dropped_and_identifiers_redacted
    tenant = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
    metrics.increment("domain_conflicts_total", code: "unavailable", organization_id: tenant, customer_id: tenant)
    metrics.increment("http_requests_total", method: "GET", route: "/reservas/#{tenant}", status: "200")
    metrics.increment("external_calls_total", provider: "simulator", kind: "sim_#{"ab12" * 8}", outcome: "ok")
    output = metrics.render

    refute_match UUID, output
    refute_includes output, "organization_id"
    refute_includes output, "customer_id"
    assert_includes output, 'locentra_domain_conflicts_total{code="unavailable"} 1'
    assert_includes output, 'route="redacted"'
    assert_includes output, 'kind="redacted"'
  end

  def test_label_values_are_escaped_and_truncated
    metrics.increment("domain_conflicts_total", code: %(a"b\\c\nd))
    metrics.increment("domain_conflicts_total", code: "x" * 120)
    output = metrics.render

    assert_includes output, %(code="a\\"b\\\\c\\nd")
    assert_includes output, %(code="#{"x" * 80}")
  end

  def test_external_totals_replace_values_and_gauge_families_drop_absent_series
    metrics.set_counter("jobs_retries_total", 4, queue: "default", kind: "payments.submit")
    metrics.set_counter("jobs_retries_total", 7, queue: "default", kind: "payments.submit")
    metrics.replace_gauges("jobs_queue_size", [[2, { queue: "default", status: "pending" }], [1, { queue: "lenta", status: "pending" }]])
    metrics.replace_gauges("jobs_queue_size", [[0, { queue: "default", status: "pending" }]])
    output = metrics.render

    assert_includes output, 'locentra_jobs_retries_total{kind="payments.submit",queue="default"} 7'
    assert_equal 7, metrics.counter_value("jobs_retries_total", queue: "default", kind: "payments.submit")
    assert_includes output, 'locentra_jobs_queue_size{queue="default",status="pending"} 0'
    refute_includes output, 'queue="lenta"'
  end

  def test_request_logger_normalizes_unknown_methods_and_keeps_route_templates
    log = StringIO.new
    logger = O::StructuredLogger.new(io: log, level: "info")
    app = lambda do |env|
      env["locentra.route"] = "/reservas/:id" if env["PATH_INFO"].start_with?("/reservas/")
      [200, {}, ["ok"]]
    end
    middleware = Locentra::Interfaces::HTTP::RequestLogger.new(app, logger: logger, metrics: metrics)
    reservation = "0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
    _, headers, = middleware.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/reservas/#{reservation}", "HTTP_X_REQUEST_ID" => "req-unit-0001")
    middleware.call("REQUEST_METHOD" => "FOOBAR", "PATH_INFO" => "/qualquer", "HTTP_X_REQUEST_ID" => "curto")
    output = metrics.render

    assert_equal "req-unit-0001", headers["x-request-id"]
    assert_includes output, 'locentra_http_requests_total{method="GET",route="/reservas/:id",status="200"} 1'
    assert_includes output, 'locentra_http_requests_total{method="OTHER",route="unmatched",status="200"} 1'
    refute_includes output, reservation
    entries = log.string.lines.map { |line| JSON.parse(line) }

    assert_equal "req-unit-0001", entries.first["request_id"]
    assert_match UUID, entries.last["request_id"], "identificador inválido é substituído por um gerado"
  end
end
