class Dea::StagingTaskRegistry
  include Enumerable

  def register(task)
    tasks[task.task_id] = task
  end

  def unregister(task)
    tasks.delete(task.task_id)
  end

  def registered_task(task_id)
    tasks[task_id]
  end

  def each(&block)
    tasks.each_value(&block)
  end

  private

  def tasks
    @tasks ||= {}
  end
end
