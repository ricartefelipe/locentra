# frozen_string_literal: true

# Barreira de sincronização para testes concorrentes: as threads só prosseguem quando todas chegam.
# Usa ConditionVariable (sem sleeps); um tempo máximo evita travar a suíte se houver defeito.
class Barrier
  def initialize(parties, timeout: 10)
    @parties = parties
    @timeout = timeout
    @count = 0
    @generation = 0
    @mutex = Thread::Mutex.new
    @condition = Thread::ConditionVariable.new
  end

  def wait
    @mutex.synchronize do
      generation = @generation
      @count += 1
      if @count == @parties
        @count = 0
        @generation += 1
        @condition.broadcast
      else
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        while generation == @generation
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raise "barreira não completada em #{@timeout}s" if remaining <= 0

          @condition.wait(@mutex, remaining)
        end
      end
    end
  end
end

# Decorador que pausa um método do objeto real numa barreira antes (ou depois) de executá-lo.
# `skip` ignora as primeiras chamadas de cada thread (por exemplo, pausar só na segunda leitura).
class PausingProxy < BasicObject
  def initialize(target, method_name, barrier, after: false, times: 1, skip: 0)
    @target = target
    @method_name = method_name
    @barrier = barrier
    @after = after
    @remaining = ::Hash.new(times)
    @skipped = ::Hash.new(skip)
    @mutex = ::Thread::Mutex.new
  end

  def method_missing(name, ...)
    return @target.__send__(name, ...) unless name == @method_name && take_turn

    if @after
      result = @target.__send__(name, ...)
      @barrier.wait
      result
    else
      @barrier.wait
      @target.__send__(name, ...)
    end
  end

  def respond_to_missing?(name, include_private = false) = @target.respond_to?(name, include_private)

  private

  def take_turn
    @mutex.synchronize do
      key = ::Thread.current.object_id
      if @skipped[key].positive?
        @skipped[key] -= 1
        return false
      end
      return false unless @remaining[key].positive?

      @remaining[key] -= 1
      true
    end
  end
end
