require 'rspec'
require 'progress'

describe Progress do
  before do
    Progress.stay_on_line = true
    Progress.highlight = true
    Progress.set_terminal_title = true

    allow(Progress).to receive(:start_beeper)
    allow(Progress).to receive(:time_to_print?).and_return(true)
    allow(Progress).to receive(:eta)
    allow(Progress).to receive(:elapsed).and_return('0s')
  end

  describe 'integrity' do
    before do
      @io = double(:<< => nil, :tty? => true)
      allow(Progress).to receive(:io).and_return(@io)
    end

    it 'should return result from start block' do
      expect(Progress.start('Test') do
        'test'
      end).to eq('test')
    end

    it 'should return result from step block' do
      Progress.start 1 do
        expect(Progress.step{ 'test' }).to eq('test')
      end
    end

    it 'should return result from set block' do
      Progress.start 1 do
        expect(Progress.set(1){ 'test' }).to eq('test')
      end
    end

    it 'should return result from nested block' do
      expect([1, 2, 3].with_progress.map do |a|
        [1, 2, 3].with_progress.map do |b|
          a * b
        end
      end).to eq([[1, 2, 3], [2, 4, 6], [3, 6, 9]])
    end

    it 'should not raise errors on extra step or stop' do
      expect do
        3.times_with_progress do
          Progress.start 'simple' do
            Progress.step
            Progress.step
            Progress.step
          end
          Progress.step
          Progress.stop
        end
        Progress.step
        Progress.stop
      end.not_to raise_error
    end

    describe Enumerable do
      before :each do
        @a = 0...1000
      end

      describe 'with_progress' do
        it 'should not break each' do
          reference = @a.each
          @a.with_progress.each do |n|
            expect(n).to eq(reference.next)
          end
          expect{ reference.next }.to raise_error(StopIteration)
        end

        it 'should not break find' do
          default = proc{ 'default' }
          expect(@a.with_progress.find{ |n| n == 100 }).to eq(@a.find{ |n| n == 100 })
          expect(@a.with_progress.find{ |n| n == 10_000 }).to eq(@a.find{ |n| n == 10_000 })
          expect(@a.with_progress.find(default){ |n| n == 10_000 }).to eq(@a.find(default){ |n| n == 10_000 })
        end

        it 'should not break map' do
          expect(@a.with_progress.map{ |n| n * n }).to eq(@a.map{ |n| n * n })
        end

        it 'should not break grep' do
          expect(@a.with_progress.grep(100)).to eq(@a.grep(100))
        end

        it 'should not break each_cons' do
          reference = @a.each_cons(3)
          @a.with_progress.each_cons(3) do |values|
            expect(values).to eq(reference.next)
          end
          expect{ reference.next }.to raise_error(StopIteration)
        end

        describe 'with_progress.with_progress' do
          it 'should not change existing instance' do
            wp = @a.with_progress('hello')
            expect{ wp.with_progress('world') }.not_to change(wp, :title)
          end

          it 'should create new instance with different title when called on WithProgress' do
            wp = @a.with_progress('hello')
            wp_wp = wp.with_progress('world')
            expect(wp.title).to eq('hello')
            expect(wp_wp.title).to eq('world')
            expect(wp_wp).not_to eq(wp)
            expect(wp_wp.enumerable).to eq(wp.enumerable)
          end
        end

        describe 'calls to each' do
          def without_warnings
            verbosity = $VERBOSE
            $VERBOSE = nil
            result = yield
            $VERBOSE = verbosity
            result
          end

          it 'should call each only once for Array' do
            enum = [1, 2, 3]
            expect(enum).to receive(:each).once.and_return(enum)
            expect(enum.with_progress.each{}).to eq(enum)
          end

          it 'should call each only once for Hash' do
            enum = {1 => 1, 2 => 2, 3 => 3}
            expect(enum).to receive(:each).once.and_return(enum)
            expect(enum.with_progress.each{}).to eq(enum)
          end

          it 'should call each only once for Set' do
            enum = [1, 2, 3].to_set
            expect(enum).to receive(:each).once.and_return(enum)
            expect(enum.with_progress.each{}).to eq(enum)
          end

          if ''.is_a?(Enumerable) # ruby1.8
            it 'should call each only once for String' do
              enum = "a\nb\nc"
              expect(enum).to receive(:each).once.and_return(enum)
              without_warnings do
                expect(enum.with_progress.each{}).to eq(enum)
              end
            end
          end

          it 'should call each only once for File (IO)' do
            enum = File.open(__FILE__)
            expect(enum).to receive(:each).once.and_return(enum)
            without_warnings do
              expect(enum.with_progress.each{}).to eq(enum)
            end
          end

          it 'should call each only once for StringIO' do
            enum = StringIO.new("a\nb\nc")
            expect(enum).to receive(:each).once.and_return(enum)
            without_warnings do
              expect(enum.with_progress.each{}).to eq(enum)
            end
          end
        end
      end
    end

    describe Integer do
      let(:count){ 108 }

      it 'should not break times_with_progress' do
        reference = count.times
        count.times_with_progress do |i|
          expect(i).to eq(reference.next)
        end
        expect{ reference.next }.to raise_error(StopIteration)
      end

      it 'should not break times.with_progress' do
        reference = count.times
        count.times.with_progress do |i|
          expect(i).to eq(reference.next)
        end
        expect{ reference.next }.to raise_error(StopIteration)
      end
    end
  end

  describe 'output' do
    class ChunkIo
      attr_reader :chunks
      def initialize
        @chunks = []
      end

      def <<(data)
        @chunks << data.to_s
      end
    end

    def stub_progress_io(klass)
      io = klass.new
      allow(io).to receive(:tty?).and_return(true)
      allow(Progress).to receive(:io).and_return(io)
      io
    end

    describe 'validity' do
      def run_example_progress
        Progress.start 5, 'Test' do
          Progress.step 2, 'simle'

          Progress.step 2, 'times' do
            3.times.with_progress{}
          end

          Progress.step 'enum' do
            3.times.to_a.with_progress{}
          end
        end
      end

      def title(s)
        "\e]0;#{s}\a"
      end

      def hl(s)
        "\e[1m#{s}\e[0m"
      end

      def unhl(s)
        s.gsub(/\e\[\dm/, '')
      end

      def on_line(s)
        "\r" + s + "\e[K"
      end

      def line(s)
        s + "\n"
      end

      def on_line_n_title(s)
        [on_line(s), title(unhl(s))]
      end

      def line_n_title(s)
        [line(s), title(unhl(s))]
      end

      it 'should produce valid output when staying on line' do
        Progress.stay_on_line = true

        @io = stub_progress_io(ChunkIo)
        run_example_progress

        expect(@io.chunks).to eq([
          on_line_n_title("Test: #{hl '......'}"),
          on_line_n_title("Test: #{hl ' 40.0%'} - simle"),
          on_line_n_title("Test: #{hl ' 40.0%'} > #{hl '......'}"),
          on_line_n_title("Test: #{hl ' 53.3%'} > #{hl ' 33.3%'}"),
          on_line_n_title("Test: #{hl ' 66.7%'} > #{hl ' 66.7%'}"),
          on_line_n_title("Test: #{hl ' 80.0%'} > 100.0%"),
          on_line_n_title("Test: #{hl ' 80.0%'} - times"),
          on_line_n_title("Test: #{hl ' 80.0%'} > #{hl '......'}"),
          on_line_n_title("Test: #{hl ' 86.7%'} > #{hl ' 33.3%'}"),
          on_line_n_title("Test: #{hl ' 93.3%'} > #{hl ' 66.7%'}"),
          on_line_n_title('Test: 100.0% > 100.0%'),
          on_line_n_title('Test: 100.0% - enum'),
          on_line('Test: 100.0% (elapsed: 0s) - enum') + "\n",
          title(''),
        ].flatten)
      end

      it 'should produce valid output when not staying on line' do
        Progress.stay_on_line = false

        @io = stub_progress_io(ChunkIo)
        run_example_progress

        expect(@io.chunks).to eq([
          line_n_title("Test: #{hl '......'}"),
          line_n_title("Test: #{hl ' 40.0%'} - simle"),
          line_n_title("Test: #{hl ' 40.0%'} > #{hl '......'}"),
          line_n_title("Test: #{hl ' 53.3%'} > #{hl ' 33.3%'}"),
          line_n_title("Test: #{hl ' 66.7%'} > #{hl ' 66.7%'}"),
          line_n_title("Test: #{hl ' 80.0%'} > 100.0%"),
          line_n_title("Test: #{hl ' 80.0%'} - times"),
          line_n_title("Test: #{hl ' 80.0%'} > #{hl '......'}"),
          line_n_title("Test: #{hl ' 86.7%'} > #{hl ' 33.3%'}"),
          line_n_title("Test: #{hl ' 93.3%'} > #{hl ' 66.7%'}"),
          line_n_title('Test: 100.0% > 100.0%'),
          line_n_title('Test: 100.0% - enum'),
          line('Test: 100.0% (elapsed: 0s) - enum'),
          title(''),
        ].flatten)
      end
    end

    describe 'different call styles' do
      let(:count_a){ 13 }
      let(:count_b){ 17 }

      before do
        reference_io = stub_progress_io(StringIO)
        count_a.times.with_progress('Test') do
          count_b.times.with_progress{}
        end
        @reference_output = reference_io.string

        @io = stub_progress_io(StringIO)
      end

      it 'should output same when called without block' do
        Progress(count_a, 'Test')
        count_a.times do
          Progress.step do
            Progress.start(count_b)
            count_b.times do
              Progress.step
            end
            Progress.stop
          end
        end
        Progress.stop
        expect(@io.string).to eq(@reference_output)
      end

      it 'should output same when called with block' do
        Progress(count_a, 'Test') do
          count_a.times do
            Progress.step do
              Progress.start(count_b) do
                count_b.times do
                  Progress.step
                end
              end
            end
          end
        end
        expect(@io.string).to eq(@reference_output)
      end

      it 'should output same when called using with_progress on list' do
        count_a.times.to_a.with_progress('Test') do
          count_b.times.to_a.with_progress{}
        end
        expect(@io.string).to eq(@reference_output)
      end
    end
  end
end
