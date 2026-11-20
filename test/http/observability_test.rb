# frozen_string_literal: true

require "stringio"
require_relative "http_helper"
require_relative "../support/worker_support"
require_relative "../support/finance_support"

# Observabilidade de ponta a ponta: o request_id de uma requisição web aparece nos eventos, nas
# tarefas (correlation_id), no log de cada tarefa e no log das chamadas externas (webhooks enviados e
# provedor de pagamentos); /metrics segue o formato do Prometheus, inclui os agregados gravados pelos
# workers e nenhum rótulo carrega identificadores.
class ObservabilityTest < HttpTest
  include WorkerHelpers
  include FinanceHelpers

  UUID = /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/
  RESERVATION_PATH = %r{/reservas/(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})}
  PAYMENT_PATH = %r{/financeiro/pagamentos/(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})}
  SAMPLE = /\A(?<name>locentra_[a-z0-9_]+)(?:\{(?<labels>.*)\})? (?<value>-?\d+(?:\.\d+)?(?:e[+-]?\d+)?)\z/
  LABEL = /([a-z_]+)="((?:[^"\\]|\\.)*)"/

  def setup
    super
    @system.shutdown
    @log = StringIO.new
    logger = Locentra::Infrastructure::Observability::StructuredLogger.new(io: @log, level: "info")
    @system = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env), clock: @clock, logger: logger)
    finance_setup(create_organization(email: "dona@alfa.test"))
    worker_system
    login("dona@alfa.test")
  end

  def teardown
    @capture&.stop
    @worker_system&.shutdown
    super
  end

  def entries = @log.string.lines.filter_map { |line| JSON.parse(line) if line.start_with?("{") }
  def jobs_for(event) = entries.select { |e| e["event"] == "job.finished" && e["correlation_id"] == event }

  # Pelo papel do worker, que lê tarefas de qualquer organização e também as sem organização.
  def correlated_jobs(kind, request_id)
    conn = PG.connect(TestDatabase.worker_url)
    conn.exec_params("SELECT count(*) AS n FROM jobs WHERE kind = $1 AND correlation_id = $2", [kind, request_id]).first["n"].to_i
  ensure
    conn&.close
  end

  def submit_reservation(request_id, quantity: 2)
    post "/reservas", { "_csrf" => csrf, "cliente_id" => @customer.id, "filial_id" => @org[:branch].id, "inicio" => "2026-03-10T08:00",
                        "fim" => "2026-03-11T08:00", "produto" => [@chairs.id], "quantidade" => [quantity.to_s], "modo" => "confirm" },
         "HTTP_X_REQUEST_ID" => request_id
  end

  def test_request_id_reaches_events_jobs_and_outgoing_webhook_logs
    @capture = CaptureServer.new
    uc(:create_webhook).call(@actor, url: @capture.url, events: ["reservation.confirmed"])
    submit_reservation("req-reserva-0001")

    assert_equal 303, last_response.status
    assert_equal "req-reserva-0001", last_response.headers["x-request-id"]
    reservation_id = last_response.location[RESERVATION_PATH, 1]
    event = owner_query("SELECT correlation_id FROM outbox_events WHERE event_type = 'reservation.confirmed'").first

    assert_equal "req-reserva-0001", event["correlation_id"]
    audited = owner_query("SELECT DISTINCT request_id FROM audit_events WHERE resource_id = $1", [reservation_id])

    assert_equal(["req-reserva-0001"], audited.map { |row| row["request_id"] })
    request_log = entries.find { |e| e["event"] == "http.request" && e["request_id"] == "req-reserva-0001" }

    assert_equal ["/reservas", 303], request_log.values_at("route", "status")
    drain

    assert_equal(%w[email.send events.dispatch finance.sync_reservation webhooks.deliver], jobs_for("req-reserva-0001").map { |e| e["kind"] }.sort)
    assert(jobs_for("req-reserva-0001").all? { |e| e["outcome"] == "succeeded" && e["organization_id"] == @org[:organization_id] })
    delivery = entries.find { |e| e["event"] == "external.call" && e["service"] == "webhook" }

    assert_equal ["deliver", "ok", "req-reserva-0001", @org[:organization_id], "reservation.confirmed"],
                 delivery.values_at("operation", "outcome", "correlation_id", "organization_id", "event_type")
    assert_equal "reservation.confirmed", @capture.requests.pop(timeout: 5)[:headers]["x-locentra-event"]
  end

  def test_request_id_reaches_payment_provider_calls_and_webhook_processing
    @account = simulator_account
    rental = rental_of(booking.tap { |r| sync(r) })
    post "/financeiro/cobrancas/#{rental.id}/solicitar", { "_csrf" => csrf, "metodo" => "pix", "valor" => "100,00", "vencimento" => "2026-03-05" },
         "HTTP_X_REQUEST_ID" => "req-pagamento-0001"
    payment_id = last_response.location[PAYMENT_PATH, 1]

    assert_equal 1, correlated_jobs("payments.submit", "req-pagamento-0001")
    drain
    charge = entries.find { |e| e["event"] == "external.call" && e["operation"] == "create_charge" }

    assert_equal ["simulator", "ok", "req-pagamento-0001", @org[:organization_id], payment_id],
                 charge.values_at("service", "outcome", "correlation_id", "organization_id", "reference")
    assert_equal(["payments.submit"], jobs_for("req-pagamento-0001").map { |e| e["kind"] })
    post "/financeiro/pagamentos/#{payment_id}/simular", { "_csrf" => csrf }, "HTTP_X_REQUEST_ID" => "req-simulacao-0001"

    assert_equal 1, correlated_jobs("payments.process_webhook", "req-simulacao-0001")
    drain

    assert_equal "confirmed", payment(payment_id).status
    assert_includes jobs_for("req-simulacao-0001").map { |e| e["kind"] }, "payments.process_webhook"
    body = JSON.generate("id" => "evt_publico_correlacao", "event" => "PAYMENT_RECEIVED", "dateCreated" => "2026-03-02 12:00:00",
                         "payment" => { "id" => "sim_#{"b" * 32}", "status" => "RECEIVED", "value" => 1, "externalReference" => SecureRandom.uuid })
    post "/webhooks/pagamentos/#{@account["id"]}", body, "CONTENT_TYPE" => "application/json", "HTTP_ASAAS_ACCESS_TOKEN" => @account["webhook_token"],
                                                         "HTTP_X_REQUEST_ID" => "req-webhook-0001"

    assert_equal 200, last_response.status
    assert_equal 1, correlated_jobs("payments.process_webhook", "req-webhook-0001")
    drain

    assert_equal(["payments.process_webhook"], jobs_for("req-webhook-0001").map { |e| e["kind"] })
  end

  # Fluxos sem ator autenticado (recuperação de senha e cadastro) também levam o request_id da
  # requisição até a tarefa de e-mail, o log da tarefa e a auditoria.
  def test_request_id_reaches_email_jobs_of_flows_without_actor
    post "/recuperar-senha", { "email" => "dona@alfa.test" }, "HTTP_X_REQUEST_ID" => "req-senha-0001"

    assert_equal 200, last_response.status
    assert_equal 1, correlated_jobs("email.password_reset", "req-senha-0001")
    post "/cadastro", { "nome" => "Nova Dona", "email" => "nova@beta.test", "senha" => "senha-muito-segura-1", "organizacao" => "Locadora Beta",
                        "plano" => "profissional" }, "HTTP_X_REQUEST_ID" => "req-cadastro-0001"

    assert_equal 303, last_response.status
    assert_equal 1, correlated_jobs("email.confirmation", "req-cadastro-0001")
    owner = @system.uow.anonymous { |tx| @system.repos[:users].find_by_email(tx, "nova@beta.test") }
    organization_id = uc(:list_memberships).call(owner["id"]).first["organization_id"]
    created = owner_query("SELECT request_id FROM audit_events WHERE action = 'organization.created'", tenant: organization_id)

    assert_equal(["req-cadastro-0001"], created.map { |row| row["request_id"] })
    drain

    assert_equal(["email.password_reset"], jobs_for("req-senha-0001").map { |e| e["kind"] })
    assert_equal(["email.confirmation"], jobs_for("req-cadastro-0001").map { |e| e["kind"] })
    assert(jobs_for("req-senha-0001").concat(jobs_for("req-cadastro-0001")).all? { |e| e["outcome"] == "succeeded" })
  end

  # Tráfego com identificadores nos caminhos, rota inexistente, conflito tratado pelo formulário,
  # conciliação no processo web, uma entrega de webhook recusada (retentativa), a confirmação de uma
  # reserva já cancelada (transição inválida) e uma tarefa sem handler (falha permanente); a rotina de
  # manutenção grava os agregados da fila.
  def generate_signals(reservation)
    get "/reservas/#{reservation.id}"
    get "/clientes/#{@customer.id}"
    get "/rota-inexistente/#{reservation.id}"
    get "/reservas/nova"
    submit_reservation("req-conflito-0001", quantity: 500)

    assert_equal 409, last_response.status, "o formulário trata a falta de disponibilidade e ainda assim o conflito é contado"
    post "/financeiro/conciliacao", { "_csrf" => csrf }
    @capture = CaptureServer.new(status: 500)
    uc(:create_webhook).call(@actor, url: @capture.url, events: ["reservation.cancelled"])
    uc(:cancel_reservation).call(@actor, reservation.id, reason: "Cliente desistiu")
    post "/reservas/#{reservation.id}/confirmar", { "_csrf" => csrf }

    assert_includes last_response.body, "Transição inválida", "o formulário trata a transição recusada e ainda assim ela é contada"
    worker_system.transactor.call(tenant_id: @org[:organization_id]) do |tx|
      worker_system.queue.enqueue(tx, "tarefa.desconhecida", {}, priority: 10)
      worker_system.queue.enqueue(tx, "platform.housekeeping", {}, priority: 99)
    end
    drain
  end

  def test_metrics_follow_the_exposition_format_cover_the_signals_and_carry_no_identifiers
    @account = simulator_account
    reservation = booking
    generate_signals(reservation)
    get "/metrics"

    assert_equal 200, last_response.status
    assert_equal "text/plain; version=0.0.4", last_response.content_type
    samples = parse_exposition(last_response.body)
    value = ->(name, **labels) { samples.find { |s| s[:name] == name && labels.all? { |k, v| s[:labels][k.to_s] == v } }&.fetch(:value) }

    assert_operator value.call("locentra_http_requests_total", route: "/reservas/:id", method: "GET", status: "200"), :>=, 1
    assert_operator value.call("locentra_http_requests_total", route: "unmatched", status: "404"), :>=, 1
    assert_operator value.call("locentra_http_request_duration_seconds_count", route: "/reservas"), :>=, 1
    assert_operator value.call("locentra_db_pool_wait_seconds_count", pool: "web"), :>=, 1
    assert_operator value.call("locentra_domain_conflicts_total", code: "unavailable"), :>=, 1
    assert_in_delta 1, value.call("locentra_domain_conflicts_total", code: "invalid_transition").to_f, 0.001, "transição recusada contada uma vez"
    assert_operator value.call("locentra_external_calls_total", provider: "simulator", kind: "list_charges", outcome: "ok"), :>=, 1
    assert_operator value.call("locentra_jobs_queue_size", queue: "webhooks", status: "pending"), :>=, 1, "entrega reagendada"
    assert_in_delta 1, value.call("locentra_jobs_queue_size", queue: "default", status: "dead")
    refute_nil value.call("locentra_jobs_oldest_age_seconds", queue: "webhooks", status: "pending")
    refute_nil value.call("locentra_jobs_queue_stats_age_seconds")
    assert_in_delta 1, value.call("locentra_jobs_retries_total", queue: "webhooks", kind: "webhooks.deliver")
    assert_in_delta 1, value.call("locentra_jobs_dead_total", queue: "default", kind: "tarefa.desconhecida")
    identifiers = [@org[:organization_id], @customer.id, reservation.id, @chairs.id, @account["id"]]
    samples.flat_map { |s| s[:labels].values }.each do |label|
      refute_match UUID, label
      identifiers.each { |id| refute_includes label, id }
    end
  end

  def test_metrics_endpoint_requires_the_configured_token
    protected_system = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env("METRICS_TOKEN" => "token-de-metricas-0123")),
                                            clock: @clock, logger: @system.logger)
    endpoint = Rack::MockRequest.new(Rack::Lint.new(Locentra::Interfaces::HTTP::App.build(protected_system)))

    assert_equal 401, endpoint.get("/metrics").status
    assert_equal 401, endpoint.get("/metrics", "HTTP_AUTHORIZATION" => "Bearer outro-token").status
    authorized = endpoint.get("/metrics", "HTTP_AUTHORIZATION" => "Bearer token-de-metricas-0123")

    assert_equal 200, authorized.status
    assert_includes authorized.body, "# TYPE locentra_http_requests_total counter"
  ensure
    protected_system&.shutdown
  end

  private

  # Valida o formato texto 0.0.4: comentários HELP/TYPE antes das amostras de cada família, uma linha
  # TYPE por família e amostras com nome, rótulos entre chaves e valor numérico.
  def parse_exposition(body)
    types = {}
    body.lines(chomp: true).reject(&:empty?).filter_map do |line|
      if line.start_with?("# ")
        kind, name, rest = line.delete_prefix("# ").split(" ", 3)

        assert_includes %w[HELP TYPE], kind, line
        if kind == "TYPE"
          refute types.key?(name), "TYPE repetido para #{name}"
          assert_includes %w[counter gauge histogram], rest, line
          types[name] = rest
        end
        next
      end
      match = SAMPLE.match(line)

      assert match, "linha fora do formato: #{line}"
      family = match[:name].sub(/_(bucket|sum|count)\z/) { |suffix| types.key?(match[:name]) ? suffix : "" }

      assert types.key?(family), "amostra sem TYPE: #{line}"
      { name: match[:name], labels: match[:labels].to_s.scan(LABEL).to_h, value: Float(match[:value]) }
    end
  end
end
