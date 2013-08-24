module PEG
  class AbstractValue
    def ==(other)
      inspect == other.inspect
    end
  end

  class Node < AbstractValue
    attr_accessor :text, :children, :name

    def initialize(text, children=[], name=nil)
      @text, @children, @name = text, children, name
    end

    def inspect
      "#{self.class}.new(#{text.inspect}, #{children.inspect}, #{name.inspect})"
    end
  end

  class AbstractRule < AbstractValue
    attr_accessor :children

    def initialize(*children)
      @children = children
    end

    def name(value=nil)
      if value
        @name = value
        self
      else
        @name
      end
    end

    def parse(source)
      node = match(source)
      if node.text.length != source.length
        raise SyntaxError.new source[node.text.length, 50].inspect
      else
        node
      end
    end

    def new_node(text, children=[])
      Node.new(text, children, @name)
    end

    def inspect
      repr = "#{self.class}.new(#{_inspect})"
      @name ? repr + ".name(#{@name.inspect})" : repr
    end
  end

  class Literal < AbstractRule
    def initialize(literal)
      @literal = literal
      @children = []
    end

    def match(text)
      text.start_with?(@literal) ? new_node(@literal) : nil
    end

    def _inspect
      @literal.inspect
    end
  end

  class Regex < Literal
    def match(text)
      res = Regexp.new('\A' + @literal).match(text)
      res && new_node(res.to_s)
    end
  end

  class Sequence < AbstractRule
    def match(text)
      text_ = String.new(text)
      len = 0
      children = []
      @children.each do |child|
        node = child.match(text_)
        return nil unless node
        children << node
        text_ = text_.slice node.text.length..text_.length
        len += node.text.length
      end
      new_node(text.slice(0...len), children)
    end

    def _inspect
      @children.map(&:inspect).join(', ')
    end
  end

  class Or < Sequence
    def match(text)
      @children.each do |child|
        node = child.match(text)
        return new_node(node.text, [node]) if node
      end
      nil
    end
  end

  class Not < Sequence
    def match(text)
      @children[0].match(text) ? nil : new_node('')
    end
  end

  class And < Sequence
    def match(text)
      @children[0].match(text) ? new_node('') : nil
    end
  end

  class OneOrMore < Sequence
    @range = (1..Float::INFINITY)

    class << self
      attr_accessor :range
    end

    def match(text)
      text_ = String.new(text)
      len = 0
      children = []
      loop do
        node = @children[0].match(text_)
        break if not node
        children << node
        break if node.text == ''
        text_ = text_.slice node.text.length..text_.length
        len += node.text.length
      end
      in_range = self.class.range.include?(children.length)
      in_range ? new_node(text.slice(0...len), children) : nil
    end
  end

  class ZeroOrMore < OneOrMore
    @range = (0..Float::INFINITY)
  end

  class Optional < OneOrMore
    @range = (0..1)
  end

  class Reference < AbstractRule
    attr_reader :reference

    def initialize(name)
      @reference = name
      @children = []
    end

    def _inspect
      @reference.inspect
    end
  end

  class AbstractVisitor
    def self.visit(node)
      return node if node.name == nil
      send(node.name, node, node.children.map {|child| visit(child)})
    end
  end

  class GrammarGenerator < AbstractVisitor
    def self.identifier__regex(node, children)
      node.text
    end

    def self.identifier(node, children)
      identifier_regex, spacing = children
      Reference.new(identifier_regex)
    end

    def self.literal(node, children)
      Literal.new(Kernel.eval(node.text))
    end

    def self.dot(node, children)
      Regex.new('.')
    end

    def self.class(node, children)
      class_, spacing = children
      Regex.new(class_.text)
    end

    def self.definition(node, children)
      identifier, left_arrow, expression = children
      expression.name(identifier.reference)
    end

    def self.expression(node, children)
      sequence, rest = children
      rest.length == 0 ? sequence : Or.new(sequence, *rest)
    end

    def self.expression__zeroormore(node, children)
      children
    end

    def self.expression__sequence(node, children)
      slash, sequence = children
      sequence
    end

    def self.grammar(node, children)
      spacing, definitions = children
      definitions
    end

    def self.grammar__oneormore(node, children)
      children
    end

    def self.primary(node, children)
      children[0]
    end

    def self.primary__sequence(node, children)
      identifier, not_left_arrow = children
      identifier
    end

    def self.primary__parens(node, children)
      open, expression, close = children
      expression
    end

    def self.prefix__optional(node, children)
      node.text.strip  # HACK
    end

    def self.prefix(node, children)
      prefix, suffix = children
      prefix == '' ? suffix : {'&' => And, '!' => Not}.fetch(prefix).new(suffix)
    end

    def self.sequence(node, children)
      children.length == 1 ? children[0] : Sequence.new(*children)
    end

    def self.suffix__optional(node, children)
      node.text.strip  # HACK
    end

    def self.suffix(node, children)
      primary, optional_suffix = children
      optional_suffix == '' ? primary : {
        '?' => Optional,
        '*' => ZeroOrMore,
        '+' => OneOrMore,
      }.fetch(optional_suffix).new(primary)
    end
  end

  class Grammar < Sequence
    def initialize(source)
      @_nodes = peg_grammar.parse(source)
      @children = [ReferenceResolver.new(grammar).resolve]
    end

    def match(source)
      @children[0].match(source)
    end

    def grammar
      GrammarGenerator.visit(@_nodes)
    end

    def peg_grammar
      end_of_line = Or.new(
                      Literal.new("\r\n"),
                      Literal.new("\n"),
                      Literal.new("\r"),
                    )
      space = Or.new(Literal.new(" "), Literal.new("\t"), end_of_line)
      comment = Sequence.new(
                  Literal.new('#'),
                  ZeroOrMore.new(
                    Sequence.new(Not.new(end_of_line), Regex.new('.')),
                  ),
                  end_of_line,
                )
      spacing = ZeroOrMore.new(Or.new(space, comment))

      and_ = Sequence.new(Literal.new('&'), spacing)
      not_ = Sequence.new(Literal.new('!'), spacing)
      slash = Sequence.new(Literal.new('/'), spacing)
      left_arrow = Sequence.new(Literal.new('<-'), spacing)
      question = Sequence.new(Literal.new('?'), spacing)
      star = Sequence.new(Literal.new('*'), spacing)
      plus = Sequence.new(Literal.new('+'), spacing)
      open = Sequence.new(Literal.new('('), spacing)
      close = Sequence.new(Literal.new(')'), spacing)
      dot = Sequence.new(Literal.new('.'), spacing).name('dot')

      # HACK these three rules are simplified
      literal = Sequence.new(
                  Or.new(Regex.new("'.*?'"), Regex.new('".*?"')),
                  spacing
                ).name('literal')
      class_ = Sequence.new(Regex.new('\[.*?\]'), spacing).name('class')
      identifier = Sequence.new(
                     Regex.new('[A-Za-z0-9_]+').name('identifier__regex'),
                     spacing
                   ).name('identifier')

      primary = Or.new(
                  Sequence.new(
                    identifier,
                    Not.new(left_arrow)
                  ).name('primary__sequence'),
                  Sequence.new(
                    open,
                    'EXPRESSION',  # paceholder for future substitution
                    close
                  ).name('primary__parens'),
                  literal,
                  class_,
                  dot,
                ).name('primary')
      suffix = Sequence.new(
                 primary,
                 Optional.new(
                   Or.new(question, star, plus)
                 ).name('suffix__optional'),
               ).name('suffix')
      prefix = Sequence.new(
                 Optional.new(
                   Or.new(and_, not_)
                 ).name('prefix__optional'),
                 suffix
               ).name('prefix')
      sequence = ZeroOrMore.new(prefix).name('sequence')
      expression = Sequence.new(
                     sequence,
                     ZeroOrMore.new(
                       Sequence.new(
                         slash,
                         sequence
                       ).name('expression__sequence')
                     ).name('expression__zeroormore')
                   ).name('expression')
      if primary.children[1].children[1] != 'EXPRESSION'
        raise 'Invalid PEG grammar'
      else
        primary.children[1].children[1] = expression
      end
      definition = Sequence.new(
                     identifier,
                     left_arrow,
                     expression
                   ).name('definition')
      # In the original PEG paper `grammar` is specified as:
      #     grammar <- spacing definition+ end_of_file
      # but we skip `end_of_file` allowing the grammar to
      # match just a part of source in order to know where
      # the syntax error occured.
      grammar = Sequence.new(
                  spacing,
                  OneOrMore.new(definition).name('grammar__oneormore')
                ).name('grammar')

      grammar
    end
  end

  class ReferenceResolver
    def initialize(rules)
      rules = rules.map {|rule| [rule.name, rule]}
      @rules = Hash[rules]
    end

    def resolve
      name, rule = @rules.first
      _resolve(rule)
    end

    def _resolve(rule)
      if rule.class == Reference
        rule = @rules[rule.reference]
        _resolve(rule)
      else
        old_children = rule.children
        rule.children = []  # avoid infinite reqursion of _resolve
        new_children = old_children.map {|child| _resolve(child)}
        rule.children = new_children
        rule
      end
    end
  end

  class Language

    class << self
      attr_accessor :rules, :blocks
    end

    def self.rule(rule, &block)
      @rules = {} if not @rules
      @blocks = {} if not @blocks
      name = rule.split('<-')[0].strip
      @rules[name] = rule
      @blocks[name] = block
    end

    def grammar
      # we rely on the fact that 1.9+ Hash maintains order
      @grammar ||= Grammar.new(self.class.rules.values.join("\n"))
    end

    def eval(source)
      source = grammar.parse(source) if source.class == String
      _eval(source)
    end

    def _eval(node)
      block = self.class.blocks[node.name] || proc {|node, children| children}
      if block.arity == 2
        children = node.children.map {|child| _eval(child)}
        instance_exec(node, children, &block)
      elsif block.arity == 1
        instance_exec(node, &block)
      else
        raise "`rule` expects a block with signature |node| or |node, children|"
      end
    end
  end
end
