#!/usr/bin/env ruby
################################################################################
# Rambler                                                                      #
#                                                                              #
# Copyright (C) 2022 J.C. Fields (jcfields@jcfields.dev).                      #
#                                                                              #
# Permission to use, copy, modify, and/or distribute this software for any     #
# purpose with or without fee is hereby granted, provided that the above       #
# copyright notice and this permission notice appear in all copies.            #
#                                                                              #
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES     #
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF             #
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY  #
# SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES           #
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION #
# OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN       #
# CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.                     #
################################################################################

require 'erb'
require 'date'
require 'yaml'
require 'singleton'

require 'redcarpet'
require 'rubypants'

################################################################################
# Rambler class                                                                #
################################################################################

class Rambler
	def initialize()
		@config = Configuration.instance

		@post_collection = PostCollection.new read_all_post_files
		@template = Template.new @config.get(:template_file)
		@old_log = Log.new @config.get(:log_file)
		@new_log = Log.new @config.get(:log_file)
		@old_tag_log = TagLog.new @config.get(:tag_file)
		@new_tag_log = TagLog.new @config.get(:tag_file)

		@old_log.load
		@old_tag_log.load

		create_index_and_archive_pages
		create_post_pages
		create_tag_pages
		create_rss_feed

		@new_log.save
		@new_tag_log.save
		delete_unused_files
	end

	private

	def read_all_post_files()
		doc_root = @config.get(:doc_root)
		file_extension = @config.get(:file_extension)
		max_file_size = @config.get(:max_file_size)

		return Dir
			.glob(File.join doc_root, '**/*' + file_extension)
			.reject { |path| File.directory? path || File.size > max_file_size }
			.map { |path| Post.new(File.expand_path path) }
			.reject { |post| !post.isValid }
			.sort_by { |post| post.date.to_time.to_i }
			.reverse
	end

	def create_index_and_archive_pages()
		# forces rewrite if:
		# - a post has been added or removed before or on the current page,
		# - or the number of pages (and thus pagination) has changed
		old_posts = @old_log.get_all_files
			.select { |path| path.start_with? @config.get(:post_path) }
			.map { |path| File.basename path }
			.sort
			.reverse
		old_page_count = Dir
			.glob(File.join @config.get(:page_path), '*')
			.map { |path| File.basename path }
			.count { |file| file.match? /^\d+$/ }
		first_changed_page = @post_collection.find_first_changed_page old_posts
		rewrite = @post_collection.page_count != old_page_count

		page = Page.new(
			path: @config.get(:index_file),
			section: @config.get(:home_title),
			posts: @post_collection.get_posts_for_page(1),
			pages: @post_collection.get_page_range(1)
		)
		write_html_file(
			page: page,
			rewrite: rewrite || 1 >= first_changed_page
		)

		(1 .. @post_collection.page_count).each do |n|
			page = Page.new(
				path: File.join(@config.get(:page_path), n.to_s),
				section: @config.get(:archive_title),
				title: "Page #{n.to_s}",
				posts: @post_collection.get_posts_for_page(n),
				pages: @post_collection.get_page_range(n)
			)
			write_html_file(
				page: page,
				rewrite: rewrite || n >= first_changed_page
			)
		end
	end

	def create_post_pages()
		@post_collection.posts.each do |post|
			post_collection = @post_collection.filter_by_id(post.id)
			title = post_collection.posts.first.date.strftime '%B %-d, %Y' || ''

			page = Page.new(
				path: File.join(@config.get(:post_path), post.id),
				section: @config.get(:post_title),
				title: title,
				posts: post_collection.posts
			)
			write_html_file(
				page: page,
				rewrite: false
			)
		end
	end

	def create_tag_pages()
		@post_collection.tags.each do |name|
			post_collection = @post_collection.filter_by_tag(name)
			old_log_entries = @old_tag_log.find_tag(name)

			# new tag that has no previous entries
			if old_log_entries == nil
				rewrite = true
			else # existing tag, forces rewrite if pages have changed
				old_ids = @old_tag_log.find_tag(name).ids
				new_ids = post_collection.posts.map { |post| post.id }
				@new_tag_log.append name, new_ids
				rewrite = old_ids != new_ids
			end

			(1 .. post_collection.page_count).each do |n|
				page_path = File.join(@config.get(:tag_path), name)

				if n > 1
					page_path = [page_path, n.to_s].join ','
				end

				page = Page.new(
					path: page_path,
					section: @config.get(:tag_title),
					title: name,
					posts: post_collection.get_posts_for_page(n),
					pages: post_collection.get_page_range_for_tag(name, n)
				)
				write_html_file(
					page: page,
					rewrite: rewrite
				)
			end
		end
	end

	def create_rss_feed()
		page = Page.new(
			path: @config.get(:rss_file),
			posts: @post_collection.get_posts_for_rss()
		)
		write_rss_file(
			page: page,
			rewrite: false
		)
	end

	def write_file(page:, template:, rewrite: false)
		# writes file if:
		# - rewrite parameter is set,
		# - file does not already exist,
		# - log file is empty,
		# - at least one post was modified more recently than the file,
		# - or the configuration or template file was modified since last run
		entry = @old_log.find_file page.path
		write_file = rewrite || @config.isModified || !File.file?(page.path) ||
			entry == nil || page.posts.any? { |post| post.mtime > entry.mtime }

		if write_file
			template.write(
				path: page.path,
				section: page.section,
				title: page.title,
				posts: page.posts,
				pages: page.pages
			)
		end

		# logs file regardless of whether it was written
		@new_log.append page.path
	end

	def write_html_file(page:, rewrite: false)
		write_file(
			page: page,
			template: @template,
			rewrite: rewrite
		)
	end

	def write_rss_file(page:, rewrite: false)
		write_file(
			page: page,
			template: Template.new(@config.get(:rss_template)),
			rewrite: rewrite
		)
	end

	def delete_unused_files()
		old_files = @old_log.get_all_files
		new_files = @new_log.get_all_files

		# deletes pages from previous run that are no longer necessary
		(old_files - new_files).each do |page_path|
			if File.file? page_path
				begin
					File.delete page_path
					puts "Deleted file: #{page_path}"
				rescue
					STDERR.puts "Could not delete file: #{page_path}"
				end
			end
		end
	end
end

################################################################################
# Page class                                                                   #
################################################################################

class Page
	attr_reader :path, :posts, :pages, :section, :title

	def initialize(path:, posts:, pages: [], section: '', title: '')
		@path = path

		@posts = posts
		@pages = pages

		@section = section
		@title = title
	end
end

################################################################################
# Template class                                                               #
################################################################################

class Template
	def initialize(path)
		@file = ''

		if File.file? path
			@file = File.read path
		else
			STDERR.puts "Could not read template: #{path}"
		end
	end

	def write(path:, section: '', title: '', posts:, pages: [])
		return if @file.empty?

		contents = ERB.new(@file).result_with_hash(
			section: section,
			title: title,
			posts: posts,
			pages: pages
		)

		begin
			File.write path, contents
			puts "Wrote file: #{path}"
		rescue
			STDERR.puts "Could not write file: #{path}"
		end
	end
end

################################################################################
# PostCollection class                                                         #
################################################################################

class PostCollection
	attr_reader :posts, :tags, :page_count

	def initialize(posts)
		@posts = posts

		config = Configuration.instance
		@posts_per_page = config.get(:posts_per_page)
		@rss_posts = config.get(:rss_posts)

		@tags = posts
			.map { |post| post.tags.map { |tag| tag.name } }
			.flatten
			.uniq
			.sort
		@page_count = (Float(posts.length) / @posts_per_page).ceil
	end

	def get_posts_for_page(n)
		start = n * @posts_per_page - @posts_per_page
		return @posts.slice start, @posts_per_page
	end

	def get_posts_for_rss()
		return @posts.first @rss_posts
	end

	def get_page_range(current_page)
		return (1 .. @page_count).map do |n|
			link = [Configuration.instance.get(:page_dir), n.to_s].join '/'
			PageNumber.new n, current_page, link
		end
	end

	def get_page_range_for_tag(name, current_page)
		return (1 .. @page_count).map do |n|
			link = [Configuration.instance.get(:tag_dir), name].join '/'

			if n > 1
				link = [link, n.to_s].join ','
			end

			PageNumber.new n, current_page, link
		end
	end

	def filter_by_id(id)
		posts = [@posts.find { |post| post.id == id }]

		return PostCollection.new posts
	end

	def filter_by_tag(name)
		posts = @posts.select do |post|
			post.tags.any? { |tag| tag.name == name }
		end

		return PostCollection.new posts
	end

	def find_first_changed_page(old_posts)
		new_posts = @posts
			.map { |post| post.id }
			.sort
			.reverse

		added = new_posts.find_index((new_posts - old_posts).first)
		removed = old_posts.find_index((old_posts - new_posts).first)

		first_changed_post = [added, removed]
			.map { |n| n.to_i }
			.select { |n| n > 0 }
			.min

		if first_changed_post != nil
			return (first_changed_post / @posts_per_page).ceil
		end

		return @page_count + 1
	end
end

################################################################################
# Post class                                                                   #
################################################################################

class Post
	# parser states
	STATE_INITIAL    = 0
	STATE_PROPERTIES = 1
	STATE_BODY_TEXT  = 2

	# file formats
	FORMAT_HTML     = 'html'
	FORMAT_MARKDOWN = 'markdown'

	YAML_SEPARATOR = "---\n"

	attr_reader :mtime, :isValid, :text, :id, :link, :date, :tags, :properties

	def initialize(path)
		@path = path
		@format = FORMAT_MARKDOWN
		@mtime = (File.mtime path).to_i
		@isValid = true

		@text = ''
		@id = ''
		@link = ''
		@date = nil
		@tags = []
		@properties = {}

		parse_file
	end

	private

	def parse_file
		state = STATE_INITIAL
		yaml = ''

		File.foreach @path do |line|
			case state
			when STATE_INITIAL
				if line == YAML_SEPARATOR
					state = STATE_PROPERTIES
				end

				yaml << line
			when STATE_PROPERTIES
				if line == YAML_SEPARATOR
					state = STATE_BODY_TEXT
				else
					yaml << line
				end
			when STATE_BODY_TEXT
				@text << line
			end
		end

		begin
			@properties = YAML.load yaml || {}

			@date = @properties.fetch 'date', nil
			@tags = @properties.fetch 'tags', []
			@format = (@properties.fetch 'format', FORMAT_HTML).downcase

			if @date.class == Date
				@id = @date.strftime '%Y%m%d'

				link_dir = Configuration.instance.get(:post_dir)
				@link = [link_dir, @id].join '/'
			else
				@isValid = false
				STDERR.puts "Missing or invalid date format: #{@path}"
			end

			if @tags.class == String
				@tags = @tags.split(/\s*,\s*/)
			end

			if @tags.class == Array
				@tags = @tags
					.reject { |name| name.match? /\\\/,:\*\|\t/ }
					.map { |name| TagLink.new name }
			else
				@tags = []
				STDERR.puts "Tags must be a string or an array: #{@path}"
			end

			@text.chomp!
		rescue
			@isValid = false
			STDERR.puts "Post properties format is invalid: #{@path}"
		end

		# smart quotes
		@text = RubyPants.new(@text).to_html

		# Markdown parsing
		if @format == FORMAT_MARKDOWN
			@text = MarkdownParser.instance.render @text
		end
	end
end

################################################################################
# PageNumber class                                                             #
################################################################################

class PageNumber
	attr_reader :page, :link, :isCurrent

	def initialize(n, current_page, link)
		@page = n
		@link = link
		@isCurrent = n == current_page
	end
end

################################################################################
# TagLink class                                                                #
################################################################################

class TagLink
	attr_reader :name, :link

	def initialize(name)
		@name = name

		link_dir = Configuration.instance.get(:tag_dir)
		@link = [link_dir, ERB::Util.url_encode(name)].join '/'
	end
end

################################################################################
# Log class                                                                    #
################################################################################

class Log
	def initialize(path)
		@path = path
		@entries = []
	end

	def load()
		begin
			if File.file? @path
				@entries = File.readlines(@path).map do |line|
					mtime, path = line.split "\t"
					LogEntry.new path.chomp, mtime.to_i
				end
			end
		rescue
			@entries = []
		end
	end

	def save()
		lines = @entries
			.sort_by { |entry| entry.mtime }
			.reduce '' do |file, entry|
				file << entry.mtime.to_s + "\t" + entry.path + "\n"
			end
		begin
			File.write @path, lines
		rescue
			STDERR.puts "Could not write log file: #{@path}"
		end
	end

	def append(page_path)
		@entries.append LogEntry.new page_path, Time.now.utc.to_i
	end

	def find_file(page_path)
		return @entries.find { |entry| entry.path == page_path }
	end

	def get_all_files()
		return @entries.map { |entry| entry.path }
	end
end

################################################################################
# LogEntry class                                                               #
################################################################################

class LogEntry
	attr_reader :path, :mtime

	def initialize(path, mtime)
		@path = path
		@mtime = mtime
	end
end

################################################################################
# TagLog class                                                                 #
################################################################################

class TagLog
	def initialize(path)
		@path = path
		@entries = []
	end

	def load()
		begin
			if File.file? @path
				@entries = File.readlines(@path).map do |line|
					name, ids = line.split "\t"
					TagLogEntry.new name, ids.chomp.split(',')
				end
			end
		rescue
			@entries = []
		end
	end

	def save()
		lines = @entries
			.sort_by { |entry| entry.name }
			.reduce '' do |file, entry|
				file << entry.name + "\t" + entry.ids.join(',') + "\n"
			end
		begin
			File.write @path, lines
		rescue
			STDERR.puts "Could not write tag log file: #{@path}"
		end
	end

	def append(name, ids)
		@entries.append TagLogEntry.new name, ids
	end

	def find_tag(name)
		return @entries.find { |entry| entry.name == name }
	end
end

################################################################################
# TagLogEntry class                                                            #
################################################################################

class TagLogEntry
	attr_reader :name, :ids

	def initialize(name, ids)
		@name = name
		@ids = ids
	end
end

################################################################################
# Configuration class                                                          #
################################################################################

class Configuration
	include Singleton

	CONFIG_FILE = '.rambler.yml'

	HOME_TITLE = 'Home'
	ARCHIVE_TITLE = 'Archive'
	POST_TITLE = 'Post'
	TAG_TITLE = 'Tag'

	PAGE_DIR = 'page'
	POST_DIR = 'post'
	TAG_DIR = 'tag'
	STORE_DIR = 'store'

	INDEX_FILE = 'index.html'
	TEMPLATE_FILE = 'store/template.html.erb'
	LOG_FILE = 'store/rambler.log'
	TAG_FILE = 'store/tags.log'

	RSS_FILE = 'feed.xml'
	RSS_TEMPLATE = 'store/template.xml.erb'
	RSS_POSTS = 10

	FILE_EXTENSION = '.text'
	POSTS_PER_PAGE = 4
	MAX_FILE_SIZE = 128

	attr_reader :isModified, :isValid

	def initialize()
		@settings = {}
		@isModified = false
		@isValid = true
	end

	def load(config_root)
		config_file_path = File.join(config_root, CONFIG_FILE)
		read_config_file config_file_path
		load_parser_settings

		if @isValid && File.file?(@settings[:log_file])
			template_file_mtime = File.mtime @settings[:template_file]
			rss_template_mtime = File.mtime @settings[:rss_template]
			log_file_mtime = File.mtime @settings[:log_file]

			@isModified = template_file_mtime > log_file_mtime ||
				rss_template_mtime > log_file_mtime

			if File.file? config_file_path
				config_file_mtime = File.mtime config_file_path
				@isModified ||= config_file_mtime > log_file_mtime
			end
		end
	end

	def get(key, default='')
		return @settings.fetch key, default
	end

	private

	def read_config_file(config_file_path)
		initialize()
		config_file = {}

		if File.file? config_file_path
			begin
				config_file = YAML.load(File.read config_file_path)
			rescue
				@isValid = false
				STDERR.puts "Config file format is invalid: #{config_file_path}"
				return
			end
		end

		doc_root = config_file.fetch 'doc_root', __dir__

		set_directories(doc_root, {
			:page_path  => config_file.fetch('page_dir', PAGE_DIR),
			:post_path  => config_file.fetch('post_dir', POST_DIR),
			:tag_path   => config_file.fetch('tag_dir', TAG_DIR),
			:store_path => config_file.fetch('store_dir', STORE_DIR)
		})

		@settings[:page_dir] = File.basename @settings[:page_path]
		@settings[:post_dir] = File.basename @settings[:post_path]
		@settings[:tag_dir] = File.basename @settings[:tag_path]
		@settings[:store_dir] = File.basename @settings[:store_path]

		set_files(doc_root, {
			:index_file    => config_file.fetch('index_file', INDEX_FILE),
			:rss_file      => config_file.fetch('rss_file', RSS_FILE),
			:template_file => config_file.fetch('template_file', TEMPLATE_FILE),
			:rss_template  => config_file.fetch('rss_template', RSS_TEMPLATE),
			:log_file      => config_file.fetch('log_file', LOG_FILE),
			:tag_file      => config_file.fetch('tag_file', TAG_FILE)
		})

		@settings[:home_title] = config_file.fetch 'home_title',
			HOME_TITLE
		@settings[:archive_title] = config_file.fetch 'archive_title',
			ARCHIVE_TITLE
		@settings[:post_title] = config_file.fetch 'post_title',
			POST_TITLE
		@settings[:tag_title] = config_file.fetch 'tag_title',
			TAG_TITLE

		@settings[:file_extension] = config_file.fetch 'file_extension',
			FILE_EXTENSION
		@settings[:posts_per_page] = Integer config_file.fetch 'posts_per_page',
			POSTS_PER_PAGE
		@settings[:rss_posts] = Integer config_file.fetch 'rss_posts',
			RSS_POSTS
		@settings[:max_file_size] = Integer config_file.fetch 'max_file_size',
			MAX_FILE_SIZE

		@settings[:parser_settings] = config_file.fetch 'parser_settings', {}
	end

	def set_directories(doc_root, directories)
		if File.directory? doc_root
			@settings[:doc_root] = doc_root
		else
			@isValid = false
			STDERR.puts "Document root does not exist: #{doc_root}"
		end

		directories.each do |key, value|
			dir_path = File.join doc_root, value
			@settings[key] = dir_path

			unless File.directory? dir_path
				begin
					Dir.mkdir dir_path, 0755
					puts "Created directory: #{dir_path}"
				rescue
					STDERR.puts "Could not create directory: #{dir_path}"
				end
			end
		end

		store_path = @settings[:store_path]

		unless File.directory? store_path
			@isValid = false
			STDERR.puts "Store directory does not exist: #{store_path}"
		end
	end

	def set_files(doc_root, files)
		files.each do |key, value|
			if !value.empty?
				file_path = File.join doc_root, value
				@settings[key] = file_path
			end
		end

		template_file = @settings[:template_file]

		unless File.file? template_file
			@isValid = false
			STDERR.puts "Template file does not exist: #{template_file}"
		end

		rss_template = @settings[:rss_template]

		unless File.file? rss_template
			@isValid = false
			STDERR.puts "RSS template does not exist: #{rss_template}"
		end
	end

	def load_parser_settings()
		MarkdownParser.instance.load @settings[:parser_settings]
	end
end

################################################################################
# MarkdownParser class                                                         #
################################################################################

class MarkdownParser
	include Singleton

	def initialize()
		@parser = nil
		@settings = {}
	end

	def load(settings)
		@settings = settings
		@parser = Redcarpet::Markdown.new(Redcarpet::Render::HTML, settings)
	end

	def render(text)
		return @parser.render text
	end
end

################################################################################
# Main function                                                                #
################################################################################

def main
	# uses current directory for configuration file if not specified
	config_root = ARGV.first || __dir__

	if File.directory? config_root
		config = Configuration.instance
		config.load config_root

		if config.isValid
			Rambler.new
		end
	else
		STDERR.puts "Directory does not exist: #{config_root}"
	end
end

main