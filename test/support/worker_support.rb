# frozen_string_literal: true

require "socket"
require "locentra/interfaces/worker/runner"

# Captura e-mails em memória (somente testes).
class FakeMailer
  attr_reader :deliveries

  def initialize
    @deliveries = []
    @mutex = Thread::Mutex.new
  end

  def deliver(to:, subject:, text:, attachments: [])
    @mutex.synchronize { @deliveries << { to: to, subject: subject, text: text, attachments: attachments } }
    "<fake-#{@deliveries.size}@locentra.test>"
  end

  def link_in(index = -1) = deliveries[index][:text][%r{https?://\S+}]
  def token_in(index = -1) = URI.decode_www_form_component(link_in(index)[/token=([^&\s]+)/, 1])
end

# Servidor HTTP mínimo que registra requisições recebidas (destino de webhooks em testes).
class CaptureServer
  attr_reader :port, :requests
  attr_writer :status

  def initialize(status: 200)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @status = status
    @requests = Queue.new
    @thread = Thread.new { loop { handle(@server.accept) } }
  end

  def url(path = "/hook") = "http://127.0.0.1:#{port}#{path}"

  def stop
    @thread.kill
    @server.close
  end

  private

  def handle(socket)
    request_line = socket.gets
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = socket.read(headers["content-length"].to_i)
    @requests << { line: request_line, headers: headers, body: body }
    socket.write("HTTP/1.1 #{@status} OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
  ensure
    socket.close
  end
end

# Destino lento (somente testes): uma thread por conexão, conta as requisições em voo e o pico e só
# responde depois de `release!`.
class HoldingServer
  attr_reader :port, :requests

  def initialize(status: 200)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @status = status
    @requests = Queue.new
    @mutex = Thread::Mutex.new
    @released = Thread::ConditionVariable.new
    @open = false
    @in_flight = 0
    @max_in_flight = 0
    @handlers = []
    @thread = Thread.new { loop { accept(@server.accept) } }
  end

  def url(path = "/hook") = "http://127.0.0.1:#{port}#{path}"
  def in_flight = @mutex.synchronize { @in_flight }
  def max_in_flight = @mutex.synchronize { @max_in_flight }

  # Libera as respostas retidas e as próximas.
  def release!
    @mutex.synchronize do
      @open = true
      @released.broadcast
    end
  end

  def stop
    release!
    @thread.kill
    @handlers.each { |handler| handler.join(1) }
    @server.close
  end

  private

  def accept(socket)
    @handlers << Thread.new { handle(socket) }
  end

  def handle(socket)
    request_line = socket.gets
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = socket.read(headers["content-length"].to_i)
    hold
    @requests << { line: request_line, headers: headers, body: body }
    socket.write("HTTP/1.1 #{@status} OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
  ensure
    socket.close
  end

  def hold
    @mutex.synchronize do
      @in_flight += 1
      @max_in_flight = [@max_in_flight, @in_flight].max
      @released.wait(@mutex, 10) until @open
      @in_flight -= 1
    end
  end
end

module WorkerHelpers
  def worker_system
    @worker_system ||= begin
      @mailer = FakeMailer.new
      Locentra::System.new(Locentra::Config.from_env(TestDatabase.env), clock: @clock, logger: @system.logger, database_url: TestDatabase.worker_url,
                                                                        pool_name: "worker", pool_size: 4, mailer: @mailer)
    end
  end

  def runner
    @runner ||= Locentra::Interfaces::Worker::Runner.new(
      system: worker_system, concurrency: 1, logger: worker_system.logger, scheduler: false,
      handlers: Locentra::Interfaces::Worker::Handlers.new(worker_system, mailer: @mailer, templates: worker_system.services[:mail_templates])
    )
  end

  def drain(limit: 100) = runner.drain(limit: limit)

  def jobs(where = "TRUE")
    PG.connect(TestDatabase.worker_url).then do |conn|
      conn.exec("SELECT kind, status, attempts, last_error, organization_id FROM jobs WHERE #{where} ORDER BY created_at").to_a
    ensure
      conn&.close
    end
  end
end
