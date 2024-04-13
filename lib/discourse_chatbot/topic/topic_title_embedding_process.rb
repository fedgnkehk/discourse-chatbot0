# frozen_string_literal: true
require "openai"

module ::DiscourseChatbot

  class TopicTitleEmbeddingProcess < EmbeddingProcess

    def upsert(topic_id)
      if in_scope(topic_id)
        if !is_valid(topic_id)

          embedding_vector = get_embedding_from_api(topic_id)
  
          ::DiscourseChatbot::TopicTitleEmbedding.upsert({ topic_id: topic_id, model: SiteSetting.chatbot_open_ai_embeddings_model, embedding: "#{embedding_vector}" }, on_duplicate: :update, unique_by: :topic_id)

          ::DiscourseChatbot.progress_debug_message <<~EOS
          ---------------------------------------------------------------------------------------------------------------
          Topic Title Embeddings: I found an embedding that needed populating or updating, id: #{topic_id}
          ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
          EOS
        end
      else
        topic_title_embedding = ::DiscourseChatbot::TopicTitleEmbedding.find_by(topic_id: topic_id)
        if topic_title_embedding
          ::DiscourseChatbot.progress_debug_message <<~EOS
          ---------------------------------------------------------------------------------------------------------------
          Topic Title Embeddings: I found a Topic that was out of scope for embeddings, so deleted the embedding, id: #{topic_id}
          ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
          EOS
          topic_title_embedding.delete
        end
      end
    end

    def get_embedding_from_api(topic_id)
      begin
        self.setup_api

        topic = ::Topic.find_by(id: topic_id)
        response = @client.embeddings(
          parameters: {
            model: @model_name,
            input: topic.title
          }
        )

        if response.dig("error")
          error_text = response.dig("error", "message")
          raise StandardError, error_text
        end
      rescue StandardError => e
        Rails.logger.error("Chatbot: Error occurred while attempting to retrieve Embedding for topic id '#{topic_id}': #{e.message}")
        raise e
      end

      embedding_vector = response.dig("data", 0, "embedding")
    end


    def semantic_search(query)
      self.setup_api

      response = @client.embeddings(
        parameters: {
          model: @model_name,
          input: query[0..SiteSetting.chatbot_open_ai_embeddings_char_limit]
        }
       )

      query_vector = response.dig("data", 0, "embedding")

      begin
        threshold = SiteSetting.chatbot_forum_search_function_similarity_threshold_title
        results = 
          DB.query(<<~SQL, query_embedding: query_vector, threshold: threshold, limit: 100)
            SELECT
              topic_id,
              t.user_id,
              embedding <=> '[:query_embedding]' as cosine_distance
            FROM
              chatbot_topic_title_embeddings
            INNER JOIN
              topics t
            ON
              topic_id = t.id
            WHERE
              (1 -  (embedding <=> '[:query_embedding]')) > :threshold
            ORDER BY
              embedding <=> '[:query_embedding]'
            LIMIT :limit
          SQL

        high_ranked_users = []

        SiteSetting.chatbot_forum_search_function_reranking_group_promotion_map.each do |g|
          high_ranked_users = high_ranked_users | GroupUser.where(group_id: g).pluck(:user_id)
        end

        reranked_results = results.filter {|r| high_ranked_users.include?(r.user_id)} + results.filter {|r| !high_ranked_users.include?(r.user_id)}.first(20)

        rescue PG::Error => e
          Rails.logger.error(
            "Error #{e} querying embeddings for search #{query}",
          )
         raise MissingEmbeddingError
        end
      reranked_results.map {|p| { topic_id: p.topic_id, user_id: p.user_id, score: (1 - p.cosine_distance) } }
    end

    def in_scope(topic_id)
      return false if !::Topic.find_by(id: topic_id).present? 
      if SiteSetting.chatbot_embeddings_strategy == "categories"
        return false if !in_categories_scope(topic_id)
      else
        return false if !in_benchmark_user_scope(topic_id)
      end
      true
    end
  
    def is_valid(topic_id)
      embedding_record = ::DiscourseChatbot::TopicTitleEmbedding.find_by(topic_id: topic_id)
      return false if !embedding_record.present?
      return false if embedding_record.model != SiteSetting.chatbot_open_ai_embeddings_model
      true
    end
  
    def in_categories_scope(topic_id)
      topic = ::Topic.find_by(id: topic_id)
      return false if topic.nil?
      return false if topic.archetype == ::Archetype.private_message
      SiteSetting.chatbot_embeddings_categories.split("|").include?(topic.category_id.to_s)
    end
  
    def in_benchmark_user_scope(topic_id)
      topic = ::Topic.find_by(id: topic_id)
      return false if topic.nil?
      return false if topic.archetype == ::Archetype.private_message
      Guardian.new(benchmark_user).can_see?(topic)
    end
  end
end
