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
      chunk_text, offset, size = chunks[0]
      chunk_text.should eq(text)
      offset.should eq(0)
      size.should eq(text.size)
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
      chunks.each do |(chunk_text, offset, size)|
        chunk_text.should_not be_empty
        offset.should be >= 0
        size.should be > 0
        # Note: size may be >= chunk_text.size for combined chunks
        # (span covers original including separators)
        size.should be >= chunk_text.size
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

      # Extract text from tuples and join
      chunk_texts = chunks.map { |(t, _, _)| t }
      rejoined = chunk_texts.join(" ").gsub(/\s+/, " ").strip
      normalized_original = text.gsub(/\s+/, " ").strip

      rejoined.should eq(normalized_original)
    end

    it "handles leading/trailing whitespace correctly" do
      config = Memo::Config::Chunking.new(
        min_tokens: 100,
        max_tokens: 500,
        no_chunk_threshold: 300
      )

      text = "   Hello world   "
      chunks = Memo::Chunking.chunk_text(text, config)

      chunks.size.should eq(1)
      chunk_text, offset, size = chunks[0]
      chunk_text.should eq("Hello world")
      offset.should eq(3) # Skip leading spaces
      # SUBSTR(text, offset + 1, size) should return "Hello world"
      text[offset, size].should eq("Hello world")
    end

    it "handles non-ASCII text with correct character offsets" do
      config = Memo::Config::Chunking.new(
        min_tokens: 100,
        max_tokens: 500,
        no_chunk_threshold: 300
      )

      # UTF-8 text where character count != byte count
      text = "こんにちは世界"  # "Hello World" in Japanese
      chunks = Memo::Chunking.chunk_text(text, config)

      chunks.size.should eq(1)
      chunk_text, offset, size = chunks[0]
      chunk_text.should eq(text)
      offset.should eq(0)
      size.should eq(7) # 7 characters, not 21 bytes
      text[offset, size].should eq(text)
    end

    it "tracks correct span for combined chunks" do
      config = Memo::Config::Chunking.new(
        min_tokens: 50,   # Force combining small chunks
        max_tokens: 500,
        no_chunk_threshold: 5,   # Force splitting (below this threshold)
        tokens_per_byte: 1.0     # 1 token per byte for predictability
      )

      # Two small paragraphs that will be split then combined
      text = "Hello.\n\nWorld."
      chunks = Memo::Chunking.chunk_text(text, config)

      # Should be combined into one chunk (both are < min_tokens)
      chunks.size.should eq(1)
      chunk_text, offset, size = chunks[0]

      # Range-based chunking: chunk_text is the exact slice from original
      # This includes the \n\n separator, which is what SUBSTR will return
      chunk_text.should eq("Hello.\n\nWorld.")

      # The span covers the original text exactly
      offset.should eq(0)
      size.should eq(text.size)
      text[offset, size].should eq(chunk_text)  # Exact match guaranteed
    end
  end
end
