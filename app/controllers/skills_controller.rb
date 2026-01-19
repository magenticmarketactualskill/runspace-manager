# frozen_string_literal: true

class SkillsController < ApplicationController
  before_action :set_skill, only: %i[show edit update destroy execute register unregister]

  def index
    @skills = Skill.includes(:mcp_server).order(created_at: :desc)
    @skills = @skills.where(mcp_server_id: params[:mcp_server_id]) if params[:mcp_server_id].present?
  end

  def show
  end

  def new
    @skill = Skill.new
    @skill.mcp_server_id = params[:mcp_server_id] if params[:mcp_server_id].present?
  end

  def edit
  end

  def create
    @skill = Skill.new(skill_params)

    if @skill.save
      redirect_to @skill, notice: "Skill was successfully created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @skill.update(skill_params)
      redirect_to @skill, notice: "Skill was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @skill.destroy!
    redirect_to skills_url, notice: "Skill was successfully deleted."
  end

  # Custom actions for skill operations

  def execute
    params_hash = params[:skill_params]&.to_unsafe_h || {}

    begin
      # Convert to SkillDefinition
      skill_def = McpSkillClientServer::Skills::SkillDefinition.new(
        name: @skill.name,
        slug: @skill.name.parameterize,
        description: @skill.description,
        parameters: @skill.input_schema&.dig("properties")&.map do |name, schema|
          {
            "name" => name,
            "type" => schema["type"],
            "description" => schema["description"],
            "required" => @skill.input_schema&.dig("required")&.include?(name)
          }
        end || [],
        prompt_template: @skill.prompt_template || "{{input}}"
      )

      # Execute the skill
      start_time = Time.now
      result = McpSkillClientServer::Skills::Executor.new(skill_def, params_hash).call
      latency_ms = ((Time.now - start_time) * 1000).round

      # Record invocation
      @skill.record_invocation!(
        latency_ms: latency_ms,
        success: result[:success],
        error_message: result[:error]
      )

      if result[:success]
        render json: { success: true, output: result[:output], latency_ms: latency_ms }
      else
        render json: { success: false, error: result[:error] }, status: :unprocessable_entity
      end
    rescue StandardError => e
      @skill.record_invocation!(latency_ms: 0, success: false, error_message: e.message)
      render json: { success: false, error: e.message }, status: :internal_server_error
    end
  end

  def register
    # Register skill in the MCP server registry
    skill_def = McpSkillClientServer::Skills::SkillDefinition.new(
      name: @skill.name,
      slug: @skill.name.parameterize,
      description: @skill.description,
      parameters: build_parameters_from_schema(@skill.input_schema),
      prompt_template: @skill.prompt_template || "{{input}}"
    )

    McpSkillClientServer::Server::SkillRegistry.instance.register(skill_def)
    redirect_to @skill, notice: "Skill registered in MCP server."
  end

  def unregister
    McpSkillClientServer::Server::SkillRegistry.instance.unregister(@skill.name.parameterize)
    redirect_to @skill, notice: "Skill unregistered from MCP server."
  end

  private

  def set_skill
    @skill = Skill.find(params[:id])
  end

  def skill_params
    params.require(:skill).permit(
      :name, :description, :status, :mcp_server_id,
      :input_schema, :prompt_template, :category
    )
  end

  def build_parameters_from_schema(schema)
    return [] unless schema.is_a?(Hash) && schema["properties"]

    schema["properties"].map do |name, prop|
      {
        "name" => name,
        "type" => prop["type"] || "string",
        "description" => prop["description"],
        "required" => schema["required"]&.include?(name) || false
      }
    end
  end
end
