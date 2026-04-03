#!/usr/bin/env ruby
# frozen_string_literal: true

# Batch apply all steps from steps.json in a single Ruby process.
# Instead of spawning a separate process per step (each loading the full
# taxonomy), this script loads the taxonomy once, applies all steps in
# memory, and dumps files once at the end.
#
# Usage: bundle exec ruby scripts/batch_apply_steps.rb [steps.json]

require "bundler/setup"
require "json"
require_relative "../lib/product_taxonomy"
require_relative "../lib/product_taxonomy/commands/command"
require_relative "../lib/product_taxonomy/commands/dump_categories_command"
require_relative "../lib/product_taxonomy/commands/dump_attributes_command"
require_relative "../lib/product_taxonomy/commands/dump_values_command"
require_relative "../lib/product_taxonomy/commands/sync_en_localizations_command"
require_relative "../lib/product_taxonomy/commands/generate_docs_command"

module ProductTaxonomy
  class BatchApplySteps
    def initialize(steps_file)
      @steps_file = steps_file
      @logger = Logger.new($stdout, level: :info)
      @logger.formatter = proc { |_, _, _, msg| "#{msg}\n" }
      @modified_vertical_roots = Set.new
    end

    def run
      steps = JSON.parse(File.read(@steps_file))["steps"]
      @logger.info("Loading taxonomy...")
      Loader.load(data_path: ProductTaxonomy.data_path)
      @logger.info("Loaded. Applying #{steps.size} steps...")

      steps.each_with_index do |step, i|
        op = step["op"]
        @logger.info("[#{i + 1}/#{steps.size}] #{op}")
        begin
          send(:"apply_#{op}", step)
        rescue => e
          @logger.error("  Error: #{e.message}")
        end
      end

      @logger.info("All steps applied. Dumping files...")
      dump_all!
      @logger.info("Done.")
    end

    private

    def apply_add_attribute(step)
      name = step["name"]
      friendly_id = step["friendly_id"] || IdentifierFormatter.format_friendly_id(name)
      handle = IdentifierFormatter.format_handle(friendly_id)
      description = step["description"] || ""
      values_list = step["values"] || []

      if step["base_attribute_friendly_id"]
        base = Attribute.find_by(friendly_id: step["base_attribute_friendly_id"]) || step["base_attribute_friendly_id"]
        ExtendedAttribute.create_validate_and_add!(
          name: name,
          description: description,
          friendly_id: friendly_id,
          handle: handle,
          values_from: base,
        )
      else
        values = values_list.map do |value_name|
          value_fid = IdentifierFormatter.format_friendly_id("#{friendly_id}__#{value_name}")
          existing = Value.find_by(friendly_id: value_fid)
          next existing if existing

          Value.create_validate_and_add!(
            id: Value.next_id,
            name: value_name,
            friendly_id: value_fid,
            handle: IdentifierFormatter.format_handle(value_fid),
          )
        end

        Attribute.create_validate_and_add!(
          id: Attribute.next_id,
          name: name,
          description: description,
          friendly_id: friendly_id,
          handle: handle,
          values: values,
        )
      end
      @logger.info("  Created attribute: #{friendly_id}")
    end

    def apply_add_value(step)
      name = step["name"]
      attr_fid = step["attribute_friendly_id"]
      attribute = Attribute.find_by!(friendly_id: attr_fid)

      friendly_id = IdentifierFormatter.format_friendly_id("#{attribute.friendly_id}__#{name}")
      value = Value.create_validate_and_add!(
        id: Value.next_id,
        name: name,
        friendly_id: friendly_id,
        handle: IdentifierFormatter.format_handle(friendly_id),
      )
      attribute.add_value(value)
      @logger.info("  Created value: #{friendly_id}")
    end

    def apply_add_category(step)
      name = step["name"]
      parent_id = step["parent_id"]
      id = step["id"]

      parent = Category.find_by!(id: parent_id)
      new_category = Category.new(id: id || parent.next_child_id, name: name, parent: parent)
      new_category.validate!(:create)
      parent.add_child(new_category)
      Category.add(new_category)

      @modified_vertical_roots.add(new_category.root.id)
      @logger.info("  Created category: #{new_category.id} (#{name})")
    end

    def apply_add_attributes_to_categories(step)
      attr_fids = step["attribute_friendly_ids"]
      cat_ids = step["category_ids"]
      include_descendants = step["include_descendants"] || false

      attributes = attr_fids.map { |fid| Attribute.find_by!(friendly_id: fid) }
      categories = cat_ids.map { |id| Category.find_by!(id: id) }
      categories = categories.flat_map(&:descendants_and_self) if include_descendants

      categories.each do |category|
        attributes.each do |attribute|
          category.add_attribute(attribute) unless category.attributes.include?(attribute)
        end
        @modified_vertical_roots.add(category.root.id)
      end
      @logger.info("  Assigned #{attr_fids.size} attributes to #{categories.size} categories")
    end

    def dump_all!
      @logger.info("Dumping attributes...")
      DumpAttributesCommand.new({}).execute
      @logger.info("Dumping values...")
      DumpValuesCommand.new({}).execute
      if @modified_vertical_roots.any?
        @logger.info("Dumping categories (#{@modified_vertical_roots.size} verticals)...")
        DumpCategoriesCommand.new(verticals: @modified_vertical_roots.to_a).execute
      end
      @logger.info("Syncing en localizations...")
      SyncEnLocalizationsCommand.new(targets: "attributes,values,categories").execute
      @logger.info("Generating docs...")
      GenerateDocsCommand.new({}).execute
    end
  end
end

steps_file = ARGV[0] || "steps.json"
ProductTaxonomy::BatchApplySteps.new(steps_file).run
