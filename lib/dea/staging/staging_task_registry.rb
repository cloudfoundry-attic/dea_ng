require "dea/registry_enumeration"

module Dea
  class StagingTaskRegistry
    include Enumerable
    include RegistryEnumeration

    def register(task)
      tasks_map[task.task_id] = task
    end

    def unregister(task)
      tasks_map.delete(task.task_id)
    end

    def registered_task(task_id)
      tasks_map[task_id]
    end

    def each(&block)
      tasks_map.each_value(&block)
    end

    def tasks
      tasks_map.values
    end

    private

    def tasks_map
      @tasks_map ||= {}
    end
  end
end
