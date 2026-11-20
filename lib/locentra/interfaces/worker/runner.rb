# frozen_string_literal: true

require_relative "handlers"

module Locentra
  module Interfaces
    module Worker
      # Processo de worker: N threads de execução, uma thread de agendamento e encerramento gracioso.
      #
      # - Reivindicação em transação curta (FOR UPDATE SKIP LOCKED + lease com token).
      # - Execução sem transação aberta nem lock de banco.
      # - Conclusão/reagendamento exigem o token do lease (fencing): se o lease venceu e outro worker
      #   assumiu a tarefa, o resultado desta execução é descartado e registrado como "lease_lost".
      # - Leases de tarefas em execução são renovados periodicamente enquanto o handler trabalha.
      # - Mutex local não é usado como exclusão entre processos: toda coordenação é feita no banco.
      # - Retentativas e falhas permanentes são somadas pela fila em `job_outcome_totals` (todos os
      #   workers) e expostas no /metrics do processo web; o log `job.finished` traz o correlation_id
      #   da requisição que originou a tarefa.
      # - Entregas de webhooks (destinos escolhidos pelos clientes) têm fila e threads próprias: um
      #   destino lento ocupa somente essas threads, nunca as de e-mails, pagamentos e varreduras.
      # - Falha de infraestrutura (banco indisponível) nos laços espera com backoff exponencial
      #   limitado antes de tentar de novo, com log a cada potência de 2 de falhas seguidas.
      class Runner
        SCHEDULE_INTERVAL = 30
        WEBHOOK_QUEUE = "webhooks"
        MAX_FAILURE_PAUSE = 30

        def initialize(system:, handlers:, concurrency:, logger:, poll_interval: 1.0, queues: ["default"], webhook_concurrency: 1,
                       scheduler: true)
          @system = system
          @handlers = handlers
          @concurrency = concurrency
          @logger = logger
          @poll_interval = poll_interval
          @lanes = [[queues, concurrency], [[WEBHOOK_QUEUE], webhook_concurrency]].reject { |_, threads| threads.zero? }
          @queues = @lanes.flat_map(&:first).uniq
          @scheduler = scheduler
          @wakeup = Thread::Queue.new
          @running = {}
          @running_mutex = Thread::Mutex.new
          @stopping = false
          @name = Infrastructure::Jobs::Queue.worker_name
        end

        def run
          reader, writer = IO.pipe
          %w[TERM INT].each { |signal| Signal.trap(signal) { writer.write_nonblock(".", exception: false) } }
          @logger.info(event: "worker.started", worker: @name, concurrency: @concurrency, lanes: @lanes.to_h { |q, n| [q.join(","), n] })
          threads = start_threads
          reader.wait_readable
          stop(threads)
        ensure
          reader&.close
          writer&.close
        end

        def start_threads
          workers = @lanes.flat_map { |queues, threads| Array.new(threads) { queues } }.each_with_index.map do |queues, i|
            Thread.new { work_loop(i, queues) }
          end
          extra = [Thread.new { heartbeat_loop }]
          extra << Thread.new { schedule_loop } if @scheduler
          workers + extra
        end

        def stop(threads, timeout: 25)
          @stopping = true
          @wakeup.close
          @logger.info(event: "worker.stopping", worker: @name)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          threads.each { |t| t.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.1].max) }
          @system.shutdown
          @logger.info(event: "worker.stopped", worker: @name)
        end

        # Executa no máximo `limit` tarefas prontas de todas as filas e retorna quantas processou (testes).
        def drain(limit: 100)
          processed = 0
          while processed < limit && (job = claim)
            process(job)
            processed += 1
          end
          processed
        end

        def process(job)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          track(job) do
            result = @handlers.call(job)
            finished = @system.transactor.call { |tx| @system.queue.complete(tx, job) }
            log_result(job, finished ? "succeeded" : "lease_lost", started, result: result)
          end
        rescue PermanentFailure, KeyError => e
          finished = @system.transactor.call { |tx| @system.queue.kill(tx, job, e) }
          log_result(job, finished ? "dead" : "lease_lost", started, error: e)
        rescue StandardError => e
          retried = @system.transactor.call { |tx| @system.queue.retry_later(tx, job, e) }
          log_result(job, retried ? "retry" : "lease_lost_or_dead", started, error: e)
        end

        private

        def claim(queues = @queues)
          @system.transactor.call { |tx| @system.queue.claim(tx, worker: @name, limit: 1, queues: queues).first }
        end

        def work_loop(index, queues)
          resilient("worker.thread_crashed", thread: index) do
            job = claim(queues)
            job ? process(job) : @wakeup.pop(timeout: @poll_interval)
          end
        end

        def heartbeat_loop
          resilient("worker.heartbeat_failed") do
            @wakeup.pop(timeout: 20)
            jobs = @running_mutex.synchronize { @running.values }
            jobs.each do |job|
              renewed = @system.transactor.call { |tx| @system.queue.heartbeat(tx, job) }
              @logger.warn(event: "worker.lease_lost", job_id: job.id, kind: job.kind) unless renewed
            end
          end
        end

        def schedule_loop
          resilient("worker.scheduler_failed") do
            schedule
            @wakeup.pop(timeout: SCHEDULE_INTERVAL)
          end
        end

        # Repete o passo até o encerramento. Depois de uma falha, espera 1, 2, 4... até
        # MAX_FAILURE_PAUSE segundos (o encerramento interrompe a espera) e zera a contagem no
        # primeiro passo sem erro.
        def resilient(event, **fields)
          failures = 0
          until @stopping
            begin
              yield
              failures = 0
            rescue StandardError => e
              failures += 1
              if failures.nobits?(failures - 1)
                @logger.error(event: event, worker: @name, error: e.class.name, message: e.message, consecutive_failures: failures, **fields)
              end
              @wakeup.pop(timeout: [2**[failures - 1, 5].min, MAX_FAILURE_PAUSE].min)
            end
          end
        end

        # Chaves únicas por janela de tempo: vários workers agendando ao mesmo tempo geram uma tarefa.
        def schedule
          now = @system.clock.now
          bucket = Time.at(now.to_i - (now.to_i % 60)).utc.iso8601
          @system.transactor.call do |tx|
            @system.queue.enqueue(tx, "platform.fanout", { "bucket" => bucket }, unique_key: "fanout:#{bucket}", priority: 20)
            @system.queue.enqueue(tx, "platform.housekeeping", {}, unique_key: "housekeeping:#{bucket}", priority: 90)
          end
        end

        def track(job)
          @running_mutex.synchronize { @running[job.id] = job }
          yield
        ensure
          @running_mutex.synchronize { @running.delete(job.id) }
        end

        def log_result(job, outcome, started, result: nil, error: nil)
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          @system.metrics.observe("job_duration_seconds", duration, kind: job.kind)
          fields = { event: "job.finished", job_id: job.id, kind: job.kind, attempt: job.attempts, outcome: outcome,
                     duration_ms: (duration * 1000).round(1), organization_id: job.organization_id, correlation_id: job.correlation_id }
          fields[:result] = result.to_s[0, 200] if result
          fields[:error] = "#{error.class.name}: #{error.message}"[0, 500] if error
          error ? @logger.warn(fields) : @logger.info(fields)
        end
      end
    end
  end
end
