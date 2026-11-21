# frozen_string_literal: true

require_relative "../unit_helper"
require "open3"
require "rbconfig"

# Domínio e aplicação carregados sozinhos, em processo separado (a suíte unitária carrega também
# adaptadores de infraestrutura no mesmo processo, o que esconderia uma dependência): nenhuma thread,
# conexão ou leitura de variável de ambiente, nenhuma constante de infraestrutura, e os casos de uso que
# conversam com portas externas (entrega de webhook, download de anexo) funcionam só com portas falsas.
class LayerIsolationTest < UnitTest
  SCRIPT = <<~'RUBY'
    reads = []
    %i[[] fetch key? has_key? include? to_h each each_pair].each do |name|
      original = ENV.method(name)
      ENV.define_singleton_method(name) { |*args, **kw, &blk| reads << [name, args.first]; original.call(*args, **kw, &blk) }
    end
    threads = Thread.list.size
    require "locentra/domain"
    require "locentra/application"
    A = Locentra::Application

    # Porta falsa: qualquer mensagem vai para o bloco (BasicObject, sem métodos herdados como find).
    class Port < BasicObject
      def initialize(handler) = @handler = handler
      def method_missing(name, *args, **kw, &blk) = @handler.call(name, args, kw, blk)
      def respond_to_missing?(*) = true
    end
    tx = Object.new
    transactor = Port.new(->(_n, _a, _k, blk) { blk.call(tx) })
    bundle = { "status" => "pending", "active" => true, "event_id" => "e1", "event_type" => "reservation.confirmed", "url" => "https://destino.example/x",
               "occurred_at" => Time.utc(2026, 3, 2), "payload" => {}, "secret_ciphertext" => "cifrado" }
    recorded = []
    circuit = { "consecutive_failures" => 1, "failing_since" => Time.utc(2026, 3, 2, 12), "paused_at" => nil, "active" => true }
    webhooks = Port.new(lambda do |name, args, _k, _b|
      case name
      when :delivery_bundle then bundle
      when :register_endpoint_result then circuit
      when :record_attempt
        recorded << args[2]
        1
      end
    end)
    http = Port.new(->(*) { raise A::Integrations::UnsafeDestination, "destino em rede interna" })
    box = Port.new(->(_n, args, *) { "segredo-de-#{args.first}" })
    signer = Port.new(->(_n, args, *) { "t=#{args[1]},v1=assinado-com-#{args[0]}" })
    logs = []
    calls = A::ExternalCalls.new(logger: Port.new(->(_n, args, *) { logs << args.first }), metrics: Port.new(->(*) {}))
    clock = Port.new(->(*) { Time.utc(2026, 3, 2, 12) })
    noop = Port.new(->(*) {})
    deliver = A::Webhooks::Deliver.new(transactor: transactor, webhooks: webhooks, http: http, box: box, signer: signer, clock: clock, calls: calls,
                                       totals: noop, audit: noop)
    delivery = begin
      deliver.call("org-1", "d1")
    rescue A::Webhooks::Deliver::DeliveryFailed => e
      e.message
    end

    actor = A::Actor.user(user_id: "u1", organization_id: "org-1", role: "owner")
    uow = Port.new(->(_n, _a, _k, blk) { blk.call(tx, actor) })
    attachments = Port.new(->(*) { { "owner_type" => "customer", "storage_key" => "a/b" } })
    storage = Port.new(->(*) { raise A::Attachments::ContentMissing, "arquivo ausente" })
    download = A::Attachments::Download.new(uow: uow, attachments: attachments, storage: storage, portal_scope: nil)
    missing = begin
      download.call(actor, "00000000-0000-7000-8000-000000000001")
    rescue Locentra::Domain::NotFound
      "not_found"
    end

    puts [Marshal.dump({ "threads" => Thread.list.size - threads, "env_reads" => reads.map { |r| r.map(&:to_s) }, "infrastructure" => defined?(Locentra::Infrastructure).to_s,
           "pg" => defined?(PG).to_s, "rack" => defined?(Rack).to_s, "delivery" => delivery, "recorded" => recorded.map { |o| o[:error] },
           "logged" => logs.map { |l| l[:outcome] }, "download" => missing })].pack("m0")
  RUBY

  def test_domain_and_application_load_alone_and_run_with_fake_ports
    lib = File.expand_path("../../../lib", __dir__)
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", SCRIPT)

    assert_predicate status, :success?, err
    result = Marshal.load(out.strip.unpack1("m0")) # rubocop:disable Security/MarshalLoad -- saída do próprio processo de teste

    assert_equal 0, result["threads"]
    assert_empty result["env_reads"], "nenhuma leitura de ENV ao carregar ou executar"
    assert_equal ["", "", ""], result.values_at("infrastructure", "pg", "rack")
    assert_equal "destino bloqueado: destino em rede interna", result["delivery"]
    assert_equal ["destino bloqueado: destino em rede interna"], result["recorded"]
    assert_equal ["blocked"], result["logged"]
    assert_equal "not_found", result["download"]
  end
end
