defmodule LangChain.ChatModels.ChatBumblebee do
  @moduledoc """
  Represents a chat model hosted by Bumblebee and accessed through an
  `Nx.Serving`.

  Many types of models can be hosted through Bumblebee, so this attempts to
  represent the most common features and provide a single implementation where
  possible.

  For streaming responses, the Bumblebee serving must be configured with
  `stream: true` and should include `stream_done: true` as well.

  Example:

      Bumblebee.Text.generation(model_info, tokenizer, generation_config,
        # ...
        stream: true,
        stream_done: true
      )

  This supports a non streaming response as well, in which case, a completed
  `LangChain.Message` is returned at the completion.

  The `stream_done` option sends a final message to let us know when the stream
  is complete and includes some token information.
  """
  use Ecto.Schema
  require Logger
  import Ecto.Changeset
  import LangChain.Utils.ApiOverride
  alias __MODULE__
  alias LangChain.ChatModels.ChatModel
  alias LangChain.Message
  alias LangChain.LangChainError
  alias LangChain.Utils
  alias LangChain.MessageDelta
  alias LangChain.Utils.ChatTemplates

  @behaviour ChatModel

  @primary_key false
  embedded_schema do
    # Name of the Nx.Serving to use when working with the LLM.
    field :serving, :any, virtual: true

    # # What sampling temperature to use, between 0 and 2. Higher values like 0.8
    # # will make the output more random, while lower values like 0.2 will make it
    # # more focused and deterministic.
    # field :temperature, :float, default: 1.0

    field :template_format, Ecto.Enum, values: [:inst, :im_start, :zephyr, :llama_2]

    # The bumblebee model may compile differently based on the stream true/false
    # option on the serving. Therefore, streaming should be enabled on the
    # serving and a stream option here can change the way data is received in
    # code. - https://github.com/elixir-nx/bumblebee/issues/295

    field :stream, :boolean, default: true

    # Seed for randomizing behavior or giving more deterministic output. Helpful
    # for testing.
    field :seed, :integer, default: nil
  end

  @type t :: %ChatBumblebee{}

  # @type call_response :: {:ok, Message.t() | [Message.t()]} | {:error, String.t()}
  # @type callback_data ::
  #         {:ok, Message.t() | MessageDelta.t() | [Message.t() | MessageDelta.t()]}
  #         | {:error, String.t()}
  @type callback_fn :: (Message.t() | MessageDelta.t() -> any())

  @create_fields [
    :serving,
    # :temperature,
    :seed,
    :template_format,
    :stream
  ]
  @required_fields [:serving]

  @doc """
  Setup a ChatBumblebee client configuration.
  """
  @spec new(attrs :: map()) :: {:ok, t} | {:error, Ecto.Changeset.t()}
  def new(%{} = attrs \\ %{}) do
    %ChatBumblebee{}
    |> cast(attrs, @create_fields)
    |> common_validation()
    |> apply_action(:insert)
  end

  @doc """
  Setup a ChatBumblebee client configuration and return it or raise an error if invalid.
  """
  @spec new!(attrs :: map()) :: t() | no_return()
  def new!(attrs \\ %{}) do
    case new(attrs) do
      {:ok, chain} ->
        chain

      {:error, changeset} ->
        raise LangChainError, changeset
    end
  end

  defp common_validation(changeset) do
    changeset
    |> validate_required(@required_fields)
  end

  @impl ChatModel
  def call(model, prompt, functions \\ [], callback_fn \\ nil)

  def call(%ChatBumblebee{} = model, prompt, functions, callback_fn) when is_binary(prompt) do
    messages = [
      Message.new_system!(),
      Message.new_user!(prompt)
    ]

    call(model, messages, functions, callback_fn)
  end

  def call(%ChatBumblebee{} = model, messages, functions, callback_fn)
      when is_list(messages) do
    if override_api_return?() do
      Logger.warning("Found override API response. Will not make live API call.")

      case get_api_override() do
        {:ok, {:ok, data} = response} ->
          # fire callback for fake responses too
          Utils.fire_callback(model, data, callback_fn)
          response

        _other ->
          raise LangChainError,
                "An unexpected fake API response was set. Should be an `{:ok, value}`"
      end
    else
      try do
        # make base api request and perform high-level success/failure checks
        case do_serving_request(model, messages, functions, callback_fn) do
          {:error, reason} ->
            {:error, reason}

          parsed_data ->
            {:ok, parsed_data}
        end
      rescue
        err in LangChainError ->
          {:error, err.message}
      end
    end
  end

  @doc false
  @spec do_serving_request(t(), [Message.t()], [Function.t()], callback_fn()) ::
          list() | struct() | {:error, String.t()}
  def do_serving_request(%ChatBumblebee{} = model, messages, _functions, callback_fn) do
    prompt = ChatTemplates.apply_chat_template!(messages, model.template_format)

    model.serving
    |> Nx.Serving.batched_run(%{text: prompt, seed: model.seed})
    |> do_process_response(model, callback_fn)
  end

  @doc false
  def do_process_response(
        %{results: [%{text: content, token_summary: _token_summary}]},
        %ChatBumblebee{} = model,
        callback_fn
      )
      when is_binary(content) do
    case Message.new(%{role: :assistant, status: :complete, content: content}) do
      {:ok, message} ->
        # execute the callback with the final message
        Utils.fire_callback(model, [message], callback_fn)
        # return a list of the complete message. As a list for compatibility.
        [message]

      {:error, changeset} ->
        reason = Utils.changeset_error_to_string(changeset)
        Logger.error("Failed to create non-streamed full message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def do_process_response(stream, %ChatBumblebee{stream: false} = model, callback_fn) do
    # Request is to NOT stream. Consume the full stream and format the data as
    # though it had not been streamed.
    full_data =
      Enum.reduce(stream, %{text: "", token_summary: nil}, fn
        {:done, token_data}, %{text: text} ->
          %{text: text, token_summary: token_data}

        data, %{text: text} = acc ->
          Map.put(acc, :text, text <> data)
      end)

    do_process_response(%{results: [full_data]}, model, callback_fn)
  end

  def do_process_response(stream, %ChatBumblebee{} = model, callback_fn) do
    chunk_processor = fn
      {:done, _token_data} ->
        final_delta = MessageDelta.new!(%{role: :assistant, status: :complete})
        Utils.fire_callback(model, [final_delta], callback_fn)
        final_delta

      content when is_binary(content) ->
        case MessageDelta.new(%{content: content, role: :assistant, status: :incomplete}) do
          {:ok, delta} ->
            Utils.fire_callback(model, [delta], callback_fn)
            delta

          {:error, changeset} ->
            reason = Utils.changeset_error_to_string(changeset)

            Logger.error(
              "Failed to process received model's MessageDelta data: #{inspect(reason)}"
            )

            raise LangChainError, reason
        end
    end

    result =
      stream
      |> Stream.map(&chunk_processor.(&1))
      |> Enum.to_list()

    # return a list of a list to mirror the way ChatGPT returns data
    [result]
  end
end
