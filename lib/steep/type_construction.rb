module Steep
  class TypeConstruction
    attr_reader :assignability
    attr_reader :source
    attr_reader :annotations
    attr_reader :var_types
    attr_reader :typing
    attr_reader :return_type
    attr_reader :block_type
    attr_reader :break_type

    def initialize(assignability:, source:, annotations:, var_types:, return_type:, block_type:, typing:, break_type: nil, self_type:)
      @assignability = assignability
      @source = source
      @annotations = annotations
      @var_types = var_types
      @typing = typing
      @return_type = return_type
      @block_type = block_type
      @break_type = break_type
      @self_type = self_type
    end

    def self_type
      annotations.self_type || @self_type
    end

    def method_type(method_name, self_type:)
      if (type = annotations.lookup_method_type(method_name))
        return type
      end

      return nil unless self_type
      return nil unless self_type.is_a?(Types::Name)

      interface = assignability.resolve_interface(self_type.name, self_type.params)

      method_types = interface.methods[method_name]
      return nil unless method_types
      return nil unless method_types.size == 1

      method_types.first
    end

    def for_new_method(method_name, node, args:, self_type:)
      annots = source.annotations(block: node)

      method_type = method_type(method_name, self_type: self_type)
      if method_type
        var_types = TypeConstruction.parameter_types(args,
                                                     method_type)
        unless TypeConstruction.valid_parameter_env?(var_types, args, method_type.params)
          typing.add_error Errors::MethodParameterTypeMismatch.new(node: node)
        end

        return_type = method_type.return_type
      else
        var_types = {}
        return_type = annots.return_type || Types::Any.new
      end

      self.class.new(assignability: assignability,
                     source: source,
                     annotations: annots,
                     var_types: var_types,
                     return_type: return_type,
                     block_type: nil,
                     typing: typing,
                     break_type: nil,
                     self_type: annotations.instance_type)
    end

    def for_block(block)
      annots = source.annotations(block: block)
      self.class.new(assignability: assignability,
                     source: source,
                     annotations: annotations + annots,
                     var_types: var_types.dup,
                     return_type: return_type,
                     block_type: annots.block_type,
                     typing: typing,
                     self_type: self_type)
    end

    def for_class(node)
      annots = source.annotations(block: node)

      self.class.new(assignability: assignability,
                     source: source,
                     annotations: annots,
                     var_types: {},
                     return_type: nil,
                     block_type: nil,
                     typing: typing,
                     self_type: annots.module_type)
    end

    def synthesize(node)
      case node.type
      when :begin
        type = each_child_node(node).map do |child|
          synthesize(child)
        end.last

        typing.add_typing(node, type)

      when :lvasgn
        var = node.children[0]
        rhs = node.children[1]

        type_assignment(var, rhs, node)

      when :lvar
        var = node.children[0]

        (variable_type(var) || Types::Any.new).tap do |type|
          typing.add_typing(node, type)
          typing.add_var_type(var, type)
        end

      when :send
        type_send(node)

      when :block
        send_node, params, block = node.children

        ret_type = type_send(send_node, with_block: true) do |recv_type, method_name, method_type|
          if method_type.block
            var_types_ = var_types.dup
            self.class.block_param_typing_pairs(param_types: method_type.block.params, param_nodes: params.children).each do |param_node, type|
              var = param_node.children[0]
              var_types_[var] = type
              typing.add_var_type(var, type)
            end

            annots = source.annotations(block: node)

            for_block = self.class.new(assignability: assignability,
                                       source: source,
                                       annotations: annotations + annots,
                                       var_types: var_types_,
                                       return_type: return_type,
                                       block_type: annots.block_type,
                                       break_type: method_type.return_type,
                                       typing: typing,
                                       self_type: self_type)

            each_child_node(params) do |param|
              for_block.synthesize(param)
            end

            if block
              for_block.check(block, method_type.block.return_type) do |expected, actual|
                typing.add_error Errors::BlockTypeMismatch.new(node: node, expected: expected, actual: actual)
              end
            end

          else
            typing.add_error Errors::UnexpectedBlockGiven.new(node: node, type: recv_type, method: method_name)
          end
        end

        typing.add_typing(node, ret_type)

      when :def
        new = for_new_method(node.children[0], node, args: node.children[1].children, self_type: annotations.instance_type)

        each_child_node(node.children[1]) do |arg|
          new.synthesize(arg)
        end

        if node.children[2]
          if new.return_type
            new.check(node.children[2], new.return_type) do |_, actual_type|
              typing.add_error(Errors::MethodBodyTypeMismatch.new(node: node,
                                                                  expected: new.return_type,
                                                                  actual: actual_type))
            end
          else
            new.synthesize(node.children[2])
          end
        end

        typing.add_typing(node, Types::Any.new)

      when :defs
        synthesize(node.children[0]).tap do |self_type|
          new = for_new_method(node.children[1], node, args: node.children[2].children, self_type: self_type)

          each_child_node(node.children[2]) do |arg|
            new.synthesize(arg)
          end

          if node.children[3]
            if new.return_type
              new.check(node.children[3], new.return_type) do |_, actual_type|
                typing.add_error(Errors::MethodBodyTypeMismatch.new(node: node,
                                                                    expected: new.return_type,
                                                                    actual: actual_type))
              end
            else
              new.synthesize(node.children[3], Types::Any.new)
            end
          end
        end

        typing.add_typing(node, Types::Name.instance(name: :Symbol))

      when :return
        value = node.children[0]

        if value
          if return_type
            check(value, return_type) do |_, actual_type|
              typing.add_error(Errors::ReturnTypeMismatch.new(node: node, expected: return_type, actual: actual_type))
            end
          else
            synthesize(value)
          end
        end

        typing.add_typing(node, Types::Any.new)

      when :break
        value = node.children[0]

        if value
          if break_type
            check(value, break_type) do |_, actual_type|
              typing.add_error Errors::BreakTypeMismatch.new(node: node, expected: break_type, actual: actual_type)
            end
          else
            synthesize(value)
          end
        end

        typing.add_typing(node, Types::Any.new)

      when :arg, :kwarg, :procarg0
        var = node.children[0]
        type = variable_type(var) || Types::Any.new

        typing.add_var_type(var, type)

      when :optarg, :kwoptarg
        var = node.children[0]
        rhs = node.children[1]
        type_assignment(var, rhs, node)

      when :int
        typing.add_typing(node, Types::Name.instance(name: :Integer))

      when :nil
        typing.add_typing(node, Types::Any.new)

      when :sym
        typing.add_typing(node, Types::Name.instance(name: :Symbol))

      when :str
        typing.add_typing(node, Types::Name.instance(name: :String))

      when :hash
        each_child_node(node) do |pair|
          raise "Unexpected non pair: #{pair.inspect}" unless pair.type == :pair
          each_child_node(pair) do |e|
            synthesize(e)
          end
        end

        typing.add_typing(node, Types::Any.new)

      when :class
        for_class(node).tap do |constructor|
          constructor.synthesize(node.children[2])
        end

        typing.add_typing(node, Types::Name.instance(name: :NilClass))

      when :self
        typing.add_typing(node, self_type || Types::Any.new)

      when :const
        type = annotations.lookup_const_type(node.children[1]) || Types::Any.new

        typing.add_typing(node, type)

      else
        raise "Unexpected node: #{node.inspect}"
      end
    end

    def check(node, type)
      type_ = synthesize(node)

      unless assignability.test(src: type_, dest: type)
        yield(type, type_)
      end
    end

    def type_assignment(var, rhs, node)
      lhs_type = variable_type(var)

      if rhs
        if lhs_type
          check(rhs, lhs_type) do |_, rhs_type|
            typing.add_error(Errors::IncompatibleAssignment.new(node: node, lhs_type: lhs_type, rhs_type: rhs_type))
          end
          typing.add_var_type(var, lhs_type)
          typing.add_typing(node, lhs_type)
          var_types[var] = lhs_type
          lhs_type
        else
          rhs_type = synthesize(rhs)
          typing.add_var_type(var, rhs_type)
          typing.add_typing(node, rhs_type)
          var_types[var] = rhs_type
          rhs_type
        end
      else
        type = lhs_type || Types::Any.new
        typing.add_var_type(var, type)
        typing.add_typing(node, type)
        var_types[var] = type
        type
      end
    end

    def type_send(node, with_block: false)
      receiver, method_name, *args = node.children
      recv_type = receiver ? synthesize(receiver) : annotations.self_type

      ret_type = assignability.method_type recv_type, method_name do |method_types|
        if method_types
          method_type = method_types.find {|method_type_|
            applicable_args?(params: method_type_.params, arguments: args) &&
              with_block == !!method_type_.block
          }

          if method_type
            yield recv_type, method_name, method_type if block_given?
            method_type.return_type
          else
            typing.add_error Errors::ArgumentTypeMismatch.new(node: node, type: recv_type, method: method_name)
            nil
          end
        else
          # no method error
          typing.add_error Errors::NoMethod.new(node: node, method: method_name, type: recv_type)
          nil
        end
      end

      typing.add_typing node, ret_type
    end

    def variable_type(var)
      var_types[var] || annotations.lookup_var_type(var.name)
    end

    def each_child_node(node)
      if block_given?
        node.children.each do |child|
          if child.is_a?(AST::Node)
            yield child
          end
        end
      else
        enum_for :each_child_node, node
      end
    end

    def applicable_args?(params:, arguments:)
      params.each_missing_argument arguments do |_|
        return false
      end

      params.each_extra_argument arguments do |_|
        return false
      end

      params.each_missing_keyword arguments do |_|
        return false
      end

      params.each_extra_keyword arguments do |_|
        return false
      end

      all_args = arguments.dup

      self.class.argument_typing_pairs(params: params, arguments: arguments.dup).each do |(param_type, argument)|
        all_args.delete_if {|a| a.equal?(argument) }

        check(argument, param_type) do |_, _|
          return false
        end
      end

      all_args.each do |arg|
        synthesize(arg)
      end

      true
    end

    def self.block_param_typing_pairs(param_types: , param_nodes:)
      pairs = []

      param_types.required.each.with_index do |type, index|
        if (param = param_nodes[index])
          pairs << [param, type]
        end
      end

      pairs
    end

    def self.argument_typing_pairs(params:, arguments:)
      keywords = {}
      unless params.required_keywords.empty? && params.optional_keywords.empty? && !params.rest_keywords
        # has keyword args
        last_arg = arguments.last
        if last_arg&.type == :hash
          arguments.pop

          last_arg.children.each do |elem|
            case elem.type
            when :pair
              key, value = elem.children
              if key.type == :sym
                name = key.children[0]

                keywords[name] = value
              end
            end
          end
        end
      end

      pairs = []

      params.flat_unnamed_params.each do |param_type|
        arg = arguments.shift
        pairs << [param_type.last, arg] if arg
      end

      if params.rest
        arguments.each do |arg|
          pairs << [params.rest, arg]
        end
      end

      params.flat_keywords.each do |name, type|
        arg = keywords.delete(name)
        if arg
          pairs << [type, arg]
        end
      end

      if params.rest_keywords
        keywords.each_value do |arg|
          pairs << [params.rest_keywords, arg]
        end
      end

      pairs
    end

    def self.parameter_types(nodes, type)
      nodes = nodes.dup

      env = {}

      type.params.required.each do |type|
        a = nodes.first
        if a&.type == :arg
          env[a.children.first] = type
          nodes.shift
        else
          break
        end
      end

      type.params.optional.each do |type|
        a = nodes.first

        if a&.type == :optarg
          env[a.children.first] = type
          nodes.shift
        else
          break
        end
      end

      if type.params.rest
        a = nodes.first
        if a&.type == :restarg
          env[a.children.first] = Types::Name.instance(name: :Array, params: [type.params.rest])
          nodes.shift
        end
      end

      nodes.each do |node|
        if node.type == :kwarg
          name = node.children[0]
          ty = type.params.required_keywords[name.name]
          env[name] = ty if ty
        end

        if node.type == :kwoptarg
          name = node.children[0]
          ty = type.params.optional_keywords[name.name]
          env[name] = ty if ty
        end

        if node.type == :kwrestarg
          ty = type.params.rest_keywords
          if ty
            env[node.children[0]] = Types::Name.instance(name: :Hash,
                                                         params: [Types::Name.instance(name: :Symbol), ty])
          end
        end
      end

      env
    end

    def self.valid_parameter_env?(env, nodes, params)
      env.size == nodes.size && env.size == params.size
    end
  end
end
