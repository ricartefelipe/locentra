# frozen_string_literal: true

require "stringio"
require "uri"
require_relative "../test_helper"
require_relative "../support/database"
require "ferrum"
require "puma"
require "puma/server"
require "locentra/interfaces/http/app"

# Puma no próprio processo, numa porta livre de 127.0.0.1, servindo a pilha Rack completa
# (estáticos, cabeçalhos de segurança e CSP) montada sobre o System de teste.
class InProcessServer
  attr_reader :port

  def initialize(app)
    @server = Puma::Server.new(app, nil, min_threads: 1, max_threads: 4, log_writer: Puma::LogWriter.null, environment: "test")
    @server.add_tcp_listener("127.0.0.1", 0)
    @port = @server.connected_ports.first
    @server.run
  end

  def url(path = "/") = "http://127.0.0.1:#{port}#{path}"

  def stop = @server.stop(true)
end

# Um Chromium headless por processo de testes (caminho em BROWSER_PATH, sem sandbox para rodar em
# contêiner); cada teste abre uma página num contexto novo, sem cookies de outros testes.
module BrowserProcess
  module_function

  def browser
    @browser ||= Ferrum::Browser.new(browser_path: ENV.fetch("BROWSER_PATH"), headless: true, timeout: 15, process_timeout: 30,
                                     window_size: [1280, 900], browser_options: { "no-sandbox" => nil, "disable-dev-shm-usage" => nil })
  end

  def quit
    @browser&.quit
    @browser = nil
  end
end

Minitest.after_run { BrowserProcess.quit }

class BrowserTest < DatabaseTest
  WAIT_SECONDS = 10
  POLL_SECONDS = 0.05
  PASSWORD = "senha-muito-segura-1"

  # Registrado antes dos scripts de cada documento: violações de CSP viram erro de console com
  # prefixo próprio, além do registro que o próprio navegador faz.
  CSP_PROBE = <<~JS
    document.addEventListener("securitypolicyviolation", (event) => {
      console.error("CSP violada: " + event.violatedDirective + " " + (event.blockedURI || "inline"));
    });
  JS

  def setup
    super
    @system.shutdown
    @log = StringIO.new
    logger = Locentra::Infrastructure::Observability::StructuredLogger.new(io: @log, level: "info")
    @system = Locentra::System.new(Locentra::Config.from_env(TestDatabase.env), clock: @clock, logger: logger)
    @server = InProcessServer.new(Locentra::Interfaces::HTTP::App.build(@system))
    @context = BrowserProcess.browser.contexts.create
    @page = @context.create_page
    @page.evaluate_on_new_document(CSP_PROBE)
    @dialogs = []
    @dialog_answer = :dismiss
    @page.on(:dialog) do |dialog|
      @dialogs << dialog.message
      @dialog_answer == :accept ? dialog.accept : dialog.dismiss
    end
  end

  def teardown
    @context&.dispose
    @server&.stop
    super
  end

  # --- Dados -----------------------------------------------------------------------------------

  # Organização A (Alfa) com cliente, câmera (2 ativos) e tripés (10 unidades); organização B (Beta)
  # em que a proprietária de A também é membro, para exercitar a seleção de organização.
  def seed_tenants
    @org = create_organization(name: "Locadora Alfa", email: "dona@alfa.test")
    @actor = @org[:actor]
    @branch = @org[:branch]
    @other = create_organization(name: "Locadora Beta", email: "dono@beta.test")
    @customer = create_customer(@actor, name: "Marina Souza")
    @camera = create_product(@actor, sku: "CAM-NAV", name: "Câmera de navegação", tracking: "serialized", pricing: { "daily_cents" => 20_000 })
    register_assets(@actor, @camera, @branch, 2)
    @tripods = create_product(@actor, sku: "TRI-NAV", name: "Tripé de navegação", tracking: "bulk", pricing: { "daily_cents" => 3_000 })
    stock(@actor, @tripods, @branch, 10)
    join_organization(@other[:actor], @org[:user_id], "dona@alfa.test", "manager")
  end

  def join_organization(inviter, user_id, email, role)
    invitation = uc(:invite_member).call(inviter, email: email, role: role)
    token = "#{inviter.organization_id}.convite-#{SecureRandom.hex(12)}"
    @system.uow.run(inviter) do |tx, _|
      tx.execute("UPDATE invitations SET token_digest = $1 WHERE id = $2", [A::Identity::Tokens.digest(token), invitation["id"]])
    end
    uc(:accept_invitation).call(token: token, user_id: user_id)
  end

  def held_reservation
    reserve(@actor, @customer, @branch, period("2026-03-10T12:00:00Z", "2026-03-11T12:00:00Z"), [line(@camera, 1)], hold_minutes: 1440)
  end

  # --- Navegação -------------------------------------------------------------------------------

  def visit(path)
    @page.go_to(@server.url(path))
    wait_until("documento de #{path} carregado") { @page.evaluate("document.readyState") == "complete" }
  end

  def current_path = URI(@page.current_url).path

  # Espera por condição com prazo: falha com a descrição se não ocorrer em WAIT_SECONDS.
  def wait_until(description, timeout: WAIT_SECONDS)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = begin
        yield
      rescue Ferrum::NodeNotFoundError, Ferrum::NoExecutionContextError, Ferrum::JavaScriptError
        nil
      end
      return result if result

      flunk "tempo esgotado esperando: #{description}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep POLL_SECONDS
    end
  end

  def find(selector) = wait_until("elemento #{selector}") { @page.at_css(selector) }
  def text_of(selector) = find(selector).text.strip
  def body_text = @page.at_css("body").text

  # Executa uma ação que leva a uma nova página e espera o novo documento terminar de carregar.
  # O marcador gravado no documento atual desaparece somente quando outro documento o substitui.
  def navigating
    marker = SecureRandom.hex(8)
    @page.evaluate("window.__marcadorDocumento = '#{marker}'")
    yield
    wait_until("nova página após a ação") do
      @page.evaluate("window.__marcadorDocumento !== '#{marker}' && document.readyState === 'complete'")
    end
  end

  def same_document?(marker) = @page.evaluate("window.__marcadorDocumento") == marker

  def fill(selector, value)
    field = find(selector)
    field.focus
    field.evaluate("this.value = ''")
    field.type(value.to_s)
    field
  end

  # Campos datetime-local recebem o valor no formato do HTML (AAAA-MM-DDTHH:MM) e disparam os eventos
  # de alteração, como faria o seletor de data do navegador.
  def set_value(selector, value)
    find(selector).evaluate(<<~JS)
      (this.value = #{value.to_json}, this.dispatchEvent(new Event("input", { bubbles: true })),
       this.dispatchEvent(new Event("change", { bubbles: true })), this.value)
    JS
  end

  def choose(selector, value)
    find(selector).select(value)
  end

  # O clique do Ferrum usa as coordenadas do elemento: ele é rolado para a área visível antes, como
  # faria um usuário.
  def click(selector) = press(find(selector))
  def press(node) = node.scroll_into_view.click

  def login_as(email, organization: nil)
    visit "/entrar"
    fill("#email", email)
    fill("#senha", PASSWORD)
    navigating { click("form[action='/entrar'] button[type=submit]") }
    return unless organization

    assert_equal "/organizacoes", current_path
    navigating { click_choice(organization) }
  end

  def click_choice(organization)
    button = wait_until("organização #{organization}") { @page.css("button.choice").find { |b| b.text.include?(organization) } }
    button.click
  end

  def active_element = @page.evaluate("document.activeElement && (document.activeElement.id || document.activeElement.className)")

  # --- Console e CSP -----------------------------------------------------------------------------

  def console_errors = @page.console.select(&:error?).map { |message| [message.text, message.location].compact.join(" ") }
  def csp_violations = @page.console.map(&:text).grep(/Content Security Policy|CSP violada/)

  # `expected` lista erros previstos pelo próprio teste (por exemplo, o 422 de um formulário com dados
  # inválidos, que o navegador registra como falha de carregamento do documento).
  def assert_clean_console(expected: [])
    assert_empty csp_violations, "violações de CSP"
    assert_empty(console_errors.reject { |text| expected.any? { |pattern| text.match?(pattern) } }, "erros de console")
  end

  def requests(method, route)
    @log.string.lines.filter_map { |line| JSON.parse(line) if line.start_with?("{") }
        .count { |e| e["event"] == "http.request" && e["method"] == method && e["route"] == route }
  end
end
