require "find"

require ENV['TM_SUPPORT_PATH'] + '/lib/textmate'
require ENV["TM_SUPPORT_PATH"] + "/lib/tm/process"
require ENV["TM_SUPPORT_PATH"] + "/lib/ui"
require ENV["TM_SUPPORT_PATH"] + "/lib/escape"
require ENV["TM_SUPPORT_PATH"] + "/lib/tm/htmloutput"
require ENV['TM_SUPPORT_PATH'] + '/lib/tm/event'

require ENV['TM_BUNDLE_SUPPORT'] + '/lib/gradle/prefs'

require 'find'
require "shellwords"
require "open3"

module Gradle
  class Project
    
    class Module 
      attr_reader :project, :path, :name, :prefix, :prefs
      
      def initialize(project, path, name)
        @project = project
        @path = path
        @name = name
        @prefs = Prefs.new(path)
      end
      
      def prefix_task(task) 
        @name.empty? ? task : "#{name}:#{task}"
      end
      
      def test_single_arg(file = ENV['TM_SELECTED_FILE']) 
        if file.nil?
          puts "No file selection"
          exit 1
        end

        clazz = File.basename(file, File.extname(file))
        prefix = @name.empty? ? "" : "#{@name}."
        "-D#{prefix}test.single=#{clazz}"
      end
      
      def test_single(file = ENV['TM_SELECTED_FILE'])
        run("test", test_single_arg(file))
      end
      
      def prompt_for_command_and_run
        previous = @prefs.get("prev_prompt")
        command = TextMate::UI.request_string(
          :title => "GradleMate", 
          :prompt => "Enter a gradle command" + (@name.empty? ? ' (for root module):' : " (for “#{@name}”):"), 
          :default => previous
        )
        
        if command.nil?
          puts "Command cancelled"
          false
        else
          @prefs.set("prev_prompt", command) unless command.nil?
          run_string(command)
          true
        end
      end

      def run_string(command)
        run(*Shellwords.shellwords(command))
      end
      
      def run(*args)
        prefixed_args = args.collect { |a| a[0..0] == "-" ? a : prefix_task(a) }
        @project.run(prefixed_args)
      end
    end
    
    attr_reader :path, :prefs
    
    def initialize(path = nil)
      @path = path || ENV['TM_PROJECT_DIRECTORY']
      @prefs = Prefs.new(@path)
      
      assert_is_gradle_project
    end

    def most_local_module(file = ENV['TM_SELECTED_FILE'])
      if file.nil?
        puts "No file selection"
        exit 1
      elsif !File.file? file
        puts "#{file} is not a file"
        exit 1
      end
      
      parent = File.expand_path("#{file}/..")
      while parent != @path do
        return module_at_path(parent) unless Dir.glob("#{parent}\/*.gradle").empty?
        parent = File.expand_path("#{parent}/..")
      end
      
      module_at_path @path
    end
    
    def open_test_result(clazz)
      test_result = path_to_test_result(clazz)
      if test_result
        TextMate.go_to(:file => test_result)
      else
        TextMate::UI.tool_tip("Could not find test result file for #{clazz}")
      end
    end  
    
    def test_single_arg(file = ENV['TM_SELECTED_FILE']) 
      if file.nil?
        puts "No file selection"
        exit 1
      end
      
      clazz = File.basename(file, File.extname(file))
      "-Dtest.single=#{clazz}"
    end
    
    def test_single(file = ENV['TM_SELECTED_FILE'])
      run("test", test_single_arg(file))
    end
    
    def run_previous_command
      previous = @prefs.get("previous_command")
      if previous.nil?
        puts "No previous command for this project"
        exit 1
      end
      
      run(previous)
    end
    
    def prompt_for_command_and_run
      previous = @prefs.get("prev_prompt")
      command = TextMate::UI.request_string(:title => "GradleMate", :prompt => "Enter a gradle command:", :default => previous)
      if command.nil?
        puts "Command cancelled"
        false
      else
        @prefs.set("prev_prompt", command) unless command.nil?
        run_string(command)
        true
      end
    end
    
    def run_string(command)
      run(*Shellwords.shellwords(command))
    end
    
    def has_gradlew
      File.executable? "#{@path}/gradlew"
    end
    
    def prefer_gradlew 
      prefer = @prefs.get("prefer_gradlew")
      prefer.nil? ? true : prefer
    end
    
    def toggle_prefer_gradlew
      @prefs.set("prefer_gradlew", !prefer_gradlew)
      prefer_gradlew
    end
    
    def gradle_command
      if has_gradlew and prefer_gradlew 
        "./gradlew"
      else
        "gradle"
      end
    end
    
    def run(*args)
      @prefs.set("previous_command", args)
      Dir.chdir(@path) do
        TextMate::HTMLOutput.show(:window_title => "GradleMate", :page_title => "GradleMate", :sub_title => @path) do |io|
          cmd = [gradle_command] + args
          io << "<span style='font-size: 120%'>#{htmlize(cmd.join(' '))}</span><br/>"
          io << "<pre>"
          
          TextMate::Process.run(cmd) do |str, type|
            str.chomp!
            str = "<span style=\"#{type == :err ? 'color: red' : ''}\">#{htmlize(str)}</span>"

            # Link individual test failures to their xml report files
            str.sub! /Test (.+) FAILED/, "Test <a href=\"javascript:TextMate.system('\\\\'#{ENV['TM_BUNDLE_SUPPORT']}/bin/open_test_result.rb\\\\' \\\\'\\1\\\\'')\">\\1</a> FAILED"

            # Italicise the task names
            str.sub! /^(<.+?>)((?::.+?)*:\S+)/, "\\1<span style='font-style: italic; color: LightSteelBlue'>\\2</span>"
            
            # Link compile error messages to the source
            str.sub! /^(<.+?>)(\/(?:.+?\/)+.+?\..+?):\s?(\d+)(.+)$/, "\\1<a href=\"javascript:TextMate.system('open \\\\'txmt://open/?url=file://\\2&line=\\3\\\\'')\">\\2:\\3</a>\\4"

            # Link test failures to the html report
            str.sub! /^(.+Cause: There were failing tests. See the report at )((?:\/.+)+)\.(.+)$/, "\\1<a href=\"javascript:TextMate.system('open \\\\'\\2/index.html\\\\'')\">\\2</a>.\\3"

            # Link build file errors
            str.sub! /^(<.+?>(?:Build file|Script) ')(.+)(')( line: (\d+))?/, "\\1<a href=\"javascript:TextMate.system('open \\\\'txmt://open/?url=file://\\2&line=\\5\\\\'')\">\\2</a>\\3\\4"
            
            # Colorise the UP-TO-DATE suffix
            str.sub! /UP-TO-DATE/, "<span style='color: Moccasin'>UP-TO-DATE</span>"

            # Colorise the UP-TO-DATE suffix
            str.sub! /SKIPPED/, "<span style='color: #ABFFE2'>UP-TO-DATE</span>"
            
            # Colorise the build status
            str.sub! /BUILD SUCCESSFUL/, "<span style='color: green; text-decoration: underline'>BUILD SUCCESSFUL</span>"
            str.sub! /BUILD FAILED/, "<span style='color: red; text-decoration: underline'>BUILD FAILED</span>"
            
            io << str + "\n"
          end
          io << "</pre>"
        end
        
        TextMate.event("info.build.complete.gradle", "Gradle Command Complete", $? == 0 ? "Command Succeeded" : "Command Failed")
        TextMate.rescan_project
      end
    end
    
    private 
    
    def assert_is_gradle_project
      if Dir.glob("#{@path}/*.gradle").empty?
        puts "#{@path} does not appear to be a Gradle project, no “*.gradle” files found @ “#{path}”"
        exit 1
      end
    end
    
    def path_to_test_result(clazz) 
      Find.find(@path) do |path|
        base = File.basename(path)
        if FileTest.directory?(path)
          if base[0] == ?. or path =~ /build\/(?!test-results$)/
            puts "pruning #{path}"
            Find.prune
          else
            next
          end
        else
          return path if base == "TEST-#{clazz}.xml"
        end
      end
      
      nil
    end
    
    def module_at_path(path) 
      Module.new(self, path, module_path_to_name(path))
    end
    
    def module_path_to_name(path) 
      if path == @path
        return ""
      end
      
      path = path[@path.length + 1..-1].sub "/", ":"
      transformer = get_config_file("transform-gradle-project-path")
      if File.executable?(transformer)
        transformedPath = Open3.popen3(transformer) { |stdin, stdout, stderr|
          stdin.puts path
          stdin.close
          stdout.read.chomp
        }
        raise "“#{transformer}” returned non zero: #{exitstatus}" unless $?.exitstatus == 0
        if transformedPath.nil?
          raise "“#{transformer}” script did not return anything"
        end
        transformedPath
      else
        path  
      end
    end
    
    def get_config_file(name) 
      "#{@path}/.textmate/#{name}"
    end
  end  
end