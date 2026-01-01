require "./spec_helper"

describe Memo::Chunking do
  describe ".chunk_text" do
    it "returns empty array for empty text" do
      config = Memo::Config::Chunking.new(
        min_tokens: 100,
        max_tokens: 500,
        no_chunk_threshold: 300
      )

      chunks = Memo::Chunking.chunk_text("", config)
      chunks.should be_empty
    end

    it "returns single chunk for text below threshold" do
      config = Memo::Config::Chunking.new(
        min_tokens: 100,
        max_tokens: 500,
        no_chunk_threshold: 300
      )

      text = "Short text that is below the no_chunk_threshold."
      chunks = Memo::Chunking.chunk_text(text, config)

      chunks.size.should eq(1)
      chunks[0].should eq(text)
    end

    it "splits text into chunks when above threshold" do
      config = Memo::Config::Chunking.new(
        min_tokens: 50,
        max_tokens: 100,
        no_chunk_threshold: 80
      )

      # Create text with multiple paragraphs
      text = (1..10).map { |i| "Paragraph #{i}. " * 20 }.join("\n\n")
      chunks = Memo::Chunking.chunk_text(text, config)

      chunks.size.should be > 1
      chunks.each do |chunk|
        chunk.should_not be_empty
      end
    end

    it "preserves text content across chunks" do
      config = Memo::Config::Chunking.new(
        min_tokens: 50,
        max_tokens: 100,
        no_chunk_threshold: 80
      )

      text = "This is a test. " * 100
      chunks = Memo::Chunking.chunk_text(text, config)

      # Join chunks and normalize whitespace
      rejoined = chunks.join(" ").gsub(/\s+/, " ").strip
      normalized_original = text.gsub(/\s+/, " ").strip

      rejoined.should eq(normalized_original)
    end
  end
end
