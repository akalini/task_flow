# encoding: utf-8
require 'task_flow/dependency_tree'

module TaskFlow
  class Registry
    attr_reader :storage
    def initialize(storage = {})
      @storage = storage
    end

    delegate :[], :[]=, :slice, :each, to: :storage

    def dependency_tree
      @dependency_tree ||= DependencyTree.new.tap do |d|
        storage.each do |name, branch|
          d[name] = branch.dependencies
        end
      end
    end

    def connection_tree
      @connection_tree ||= DependencyTree.new.tap do |d|
        storage.each do |name, branch|
          d[name] = branch.connections
        end
      end
    end

    def sorted(tree, *branches)
      target = branches.any? ? tree.combined_subtrees(*branches) : tree
      target.tsort.map { |name| storage[name] }
    end

    def instances(context)
      all = self.class.new(storage.reduce({}) do |acc, (k, v)|
        acc.merge(k => v.instance)
      end)

      all.each do |name, instance|
        instance.create_task(all, context)
      end

      all
    end

    def connect(*branches)
      sorted(dependency_tree, *branches).map do |input|
        prepared_futures.push(input.name)
        input.connect(self)
      end
    end

    def connect_including_betweens(*branches)
      sorted(connection_tree, *branches).map do |input|
        prepared_futures.push(input.name)
        input.connect(self)
      end
    end

    def proxy_dependencies(options)
      find_parents(options[:from]).each do |input|
        input.add_dependency(options[:instance])
      end
      connect_including_betweens(options[:to])
    end

    def fire_from_edges(*names)
      sorted(dependency_tree, *names).select(&:leaf?)
       .sort { |a, b| a.is_a?(AsyncTask) ? -1 : 1 }
       .map(&:fire)
    end

    def prepared_futures
      @prepared_futures ||= []
    end

    def task_state(name)
      if prepared_futures.include?(name)
        :ready
      elsif storage[name]
        :unavailable
      else
        :missing
      end
    end

    def find_parents(name)
      dependency_tree.reduce([]) do |acc, (key, value)|
        acc << storage[key] if value.include?(name)
        acc
      end
    end

    def cumulative_timeout(branch)
      sorted(connection_tree, branch).map do |task|
        if task.is_a?(AsyncTask)
          task.options[:timeout]
        else
          0.1
        end
      end.reduce(&:+)
    end

    def dependency_states(branch)
      sorted(connection_tree, branch).reduce({}) do |acc, task|
        acc.merge(task.name => task.task.state)
      end
    end
  end
end
