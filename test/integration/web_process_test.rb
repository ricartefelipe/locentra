# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/database"
require "net/http"
require "rbconfig"
require "socket"

# Processo web real (Puma com config/puma.rb e config.ru) em processo separado: a parada por TERM é
# graciosa e termina com código 0, sem relançar o sinal.
class WebProcessTest < DatabaseTest
  ROOT = File.expand_path("../..", __dir__)
  BOOT_TIMEOUT = 30

  def test_term_stops_the_web_process_with_exit_code_zero
    port = free_port
    env = TestDatabase.env("PORT" => port.to_s, "PUMA_THREADS" => "2", "WEB_CONCURRENCY" => "0")
    @pid = Process.spawn(env, RbConfig.ruby, Gem.bin_path("puma", "puma"), "-C", "config/puma.rb",
                         chdir: ROOT, out: File::NULL, err: File::NULL)
    wait_until_live(port)

    Process.kill("TERM", @pid)
    _, status = Process.wait2(@pid)
    @pid = nil

    refute_predicate status, :signaled?, "o processo não deve terminar pelo sinal relançado"
    assert_equal 0, status.exitstatus
  ensure
    stop_leftover
  end

  private

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
  ensure
    server&.close
  end

  def wait_until_live(port)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
    loop do
      flunk "o processo web terminou durante a inicialização" if Process.wait(@pid, Process::WNOHANG)
      return if live?(port)

      flunk "o processo web não respondeu em #{BOOT_TIMEOUT} s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  def live?(port)
    Net::HTTP.start("127.0.0.1", port, open_timeout: 1, read_timeout: 2) { |http| http.get("/health/live").is_a?(Net::HTTPSuccess) }
  rescue SystemCallError, Net::OpenTimeout, Net::ReadTimeout
    false
  end

  def stop_leftover
    return unless @pid

    Process.kill("KILL", @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
end
