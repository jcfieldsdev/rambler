# rambler

A basic static site generator that I use for my web site. Written in Ruby.

## Installation

The script has two external dependencies, `redcarpet` for Markdown parsing and `rubypants` for smart quotes encoding. They can be installed from the Gemfile using `bundle`:

    bundle install

## Guide

### Configuration

The script looks for a file named `.rambler.yml`. It looks in the current directory, or an argument can be passed that specifies a different directory.

The file is a YAML file like the below:

```yaml
---
# absolute path to the root directory,
# all other paths are relative to the root,
# uses current directory if not set
doc_root: /Users/jcfields/www/blue-light.net/ramblings

page_dir:  page
post_dir:  post
tag_dir:   tag
store_dir: store

# headings for each type of page
home_title:    Home
archive_title: Archive
post_title:    Post
tag_title:     Tag

index_file:    index.html
template_file: store/template.html.erb
log_file:      store/rambler.log
tag_file:      store/tags.log

rss_file:     feed.xml
rss_template: store/template.xml.erb
rss_posts:    10

# file extension for posts
file_extension: .text

# number of posts per page
posts_per_page: 4

# max file size for posts in KB
max_file_size: 128
```

YAML files start with `---` and contain a list of key/value pairs. If the configuration file cannot be parsed as YAML, the script stops running. If the configuration file is not present, the default values are used instead. If a property is not specified, the default value is used instead. The default values are the same as shown above, with the exception of `doc_root`, which uses the current working directory if not specified.

The script checks specifically for the existence of `doc_root` and `template_file` and does not continue if either does not exist. It also checks `store_dir` but tries to create it if it does not already exist; it does not continue if it does not exist and cannot be created. The other files and directories are created as necessary, but the script does not stop if one cannot be created.

Additional settings can be set for the Markdown parser (see the [redcarpet documentation](https://github.com/vmg/redcarpet)) as a hash named `parser_settings`. Unknown keys are ignored. For example, the following hash enables tables and strikethroughs:

```yaml
parser_settings:
    :tables: true
    :strikethrough: true
```

### Posting

Posts are plain text files that are placed in the location of `store_dir`. They can be placed in subdirectories and organized as desired; the script crawls the directory recursively to find posts. They can be named anything as long as they end with `file_extension`.

The format of posts is:

```yaml
---
format: html
date: 2022-03-01
tags:
- Rambler
- Ruby
---
<p>This is a post.</p>
```

The post begins with a list of properties. Like the configuration file, it is written in YAML and starts with `---`. If the properties cannot be parsed as YAML, the script displays an error and skips the post.

The `format` property is optional and can be set to "html" (if the text is written in HTML) or "markdown" (if the text is written in Markdown and must be parsed into HTML). HTML tags can be mixed into Markdown. The setting is case-insensitive. If it is omitted, the format is assumed to be Markdown.

The `date` property is required and must be in a format that can be parsed by [Date.parse](https://ruby-doc.org/stdlib-2.4.1/libdoc/date/rdoc/Date.html#method-c-parse). The script is designed to only handle one post per day at most.

The `tags` property is optional. It can be given as a list of items, each on its own line and starting with a `-`, or as a comma-separated string. Tags containing the `/` `\` `,` `:` `*` `|` characters or tabs are ignored.

Additional custom properties can be added as well. Key names can contain letters, numbers, or underscores but must begin with a letter.

The body text is written in HTML and separated from the properties by a line containing `---`.

### Templates

The script uses [ERB](https://docs.ruby-lang.org/en/2.3.0/ERB.html) for its template. The template file is specified by `template_file`.

A sample template:

```html
<!DOCTYPE html>
<html lang="en"><head><title>Ramblings<% if !title.empty? %>&mdash;<%= title %><% end %></title>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<base href="/ramblings/">
<link href="feed.xml" rel="alternate" title="Updates" type="text/xml"></head>
<body><h1>Ramblings</h1>
<h2><%= section %></h2>
<% if posts.length == 0 %>
    <p>No posts found.</p>
<% else %>
    <% posts.each do |post| %>
        <h3 id="p<%= post.id %>"><a href="<%= post.link %>" class="permalink"><%= post.date.strftime '%B %-d, %Y' %></a></h3>
        <% if post.tags.length > 0 %>
            <div class="group"><div>Tags:</div><ul class="tags">
            <% post.tags.each do |tag| %>
                <li><a href="<%= tag.link %>"><%= tag.name %></a></li>
            <% end %>
            </ul></div>
        <% end %>
        <%= post.text %>
    <% end %>
<% end %>
<% if pages.length > 0 %>
    <ul class="pages">
    <% pages.each do |page| %>
        <li><a href="<%= page.link %>"<% if page.isCurrent %> class="current"<% end %>><%= page.page %></a></li>
    <% end %>
    </ul>
<% end %>
<% if section == 'Home' %>
    <p>There is an <a href="feed.xml" class="rss">RSS feed</a> of this page.</p>
<% end %></body></html>
```

The following variables are defined for use:

- `section`: Contains the section name (as set by `home_title`, `archive_title`, `post_title`, and `tag_title`).
- `title`: Contains the page title, which varies depending on the type of page. It is blank for the home page, the page number for archive pages, the date for individual posts, and the tag name for tag pages.
- `posts`: An array containing all of the posts for the page.
  - `id`: An ID for the page consisting of the year, month, and day (equivalent to `%Y%m%d` in [Date.strftime](https://ruby-doc.org/stdlib-2.4.1/libdoc/date/rdoc/Date.html#method-i-strftime)).
  - `link`: The link to the post.
  - `date`: The date as a [Ruby Date object](https://ruby-doc.org/stdlib-2.4.1/libdoc/date/rdoc/Date.html).
  - `tags`: An array containing a list of tags associated with the post.
    - `name`: The name of the tag.
    - `link`: The link to the tag page.
  - `text`: The body text of the post.
  - `properties`: A hash containing any other properties that are defined in the post.
- `pages`: An array containing page numbers if there are more posts than can fit on the current page.
  - `page`: The page number.
  - `link`: The link to the page.
  - `isCurrent`: True for the currently selected page.

An RSS template is also written and specified by `rss_template`. A sample RSS template:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
    <channel>
        <title>Rambler</title>
        <link>https://blue-light.net/ramblings/</link>
        <description>The latest updates for Rambler.</description>
        <language>en</language>
        <% posts.each do |post| %>
            <item>
                <title></title>
                <link>https://blue-light.net/ramblings/<%= post.link %></link>
                <description><![CDATA[<%= post.text %>]]></description>
                <author>rss@blue-light.net (J.C. Fields)</author>
                <pubDate><%= post.date.rfc822 %></pubDate>
                <guid>https://blue-light.net/ramblings/<%= post.link %></guid>
            </item>
        <% end %>
    </channel>
</rss>
```

ERB exceptions are not caught, so template errors are printed to stderr.

## Compiling

When the script is run, it creates:

- A home page consisting of however many posts are defined in `posts_per_page` at most, with archive pages if necessary.
- Individual pages for each post (for permalinks).
- Pages for each tag.

The script keeps a log file to keep track of the last time it was ran. Files are only rewritten if they contain posts that were modified since the last time the script was ran, if the configuration or template file was modified since the last time the script was ran, or if the log file does not exist or does not contain an entry for the file. The easiest way to force the script to rewrite all files is to delete the log file.

The script also removes files that it wrote previously if they are no longer necessary (for example, pages for removed tags).

## Authors

- J.C. Fields <jcfields@jcfields.dev>

## License

- [ISC license](https://opensource.org/licenses/ISC)
