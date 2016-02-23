#########################
# Download Info Generator
#
# The idea behind this file is to provide a one-stop-shop for updating the
# dynamically-retrieved package URIs, and for correctly exposing that data in a
# form Hugo will automatically detect and load.
# At the end of the day, the generated YAML will look something like,
#
#     ----
#     riak_kv:
#       2.1.3:
#         - os: debian
#           versions:
#             - version: '6'
#               architectures:
#                 - arch: amd64
#                   file_info:
#                     file_name: riak_2.1.3-1_amd64.deb
#                     file_href: http://s3.amazonaws.com/downloads.basho. . .
#                     file_size: 63146820
#                     chksum_href: http://s3.amazonaws.com/downloads.bas. . .
#             - version: '7'
#               architectures:
#                 . . .
#         - os: fedora
#           versions:
#     ...
#
# Or, more generically,
#
#     ----
#     <<project_name>>
#       <<project_versoion>>
#         - os: <<operating_system_name>>
#           versions:
#             - version: <<version_number>>
#               architectures:
#                 - arch: <<architecture>>
#                   file_info:
#                     file_name: <<package_name>>
#                     file_href: <<package_url>>
#                     file_size: <<package_size>>
#                     chksum_href: <<package_sha1_url>>
#     ----
#
# NOTABLE EXCEPTION: Source tarballs don't belong to any one OS, so they're
# grouped at the same level as OSs, and are exposed in the form,
#
#     ----
#     <<project_name>>
#       <<project_versoion>>
#         - os: source
#           file_info:
#             file_name: <<package_name>>
#             file_href: <<package_url>>
#             file_size: <<package_size>>
#
# Note that we have a list of the `{os:"", versions:[]}` objects, as well as a
# lists of the `{version:"", architectures:[]}` and `{arch:"", file_info:{}}`
# objects. This will allow us to sort the lists based on the relevant
# `os`/`version`/`arch` string, and iterate over the contents of each of those
# objects appropriately.
# The project names and version numbers are going to be pulled from the metadata
# generated by our release process and that populate the index.json files in
# s3.amazonaws.com/downloads.basho.com/

require 'net/http'
require 'json'
require 'yaml'

#####
# File-Wide Constants
#####################
BASE_DOWNLOAD_URL = "http://s3.amazonaws.com/downloads.basho.com"
BASE_URI = URI(BASE_DOWNLOAD_URL)

# List of projects to track, plus metadata
# Keys are the Project Designations used in Hugo. Values are maps containing the
# root paths used in the S3 bucket, and the lowest "major" version number to
# pull information for.
PROJECTS_TO_TRACK = {
  "riak_kv"             =>{ "s3_root"=>"riak",                 "min_maj_ver"=>2.0 },
  "riak_cs"             =>{ "s3_root"=>"riak-cs",              "min_maj_ver"=>2.0 },
  "stanchion"           =>{ "s3_root"=>"stanchion",            "min_maj_ver"=>2.0 },
  "riak_cs_control"     =>{ "s3_root"=>"riak-cs-control",      "min_maj_ver"=>1.0 },
  "dataplatform"        =>{ "s3_root"=>"data-platform",        "min_maj_ver"=>1.0 },
  "dataplatform_extras" =>{ "s3_root"=>"data-platform-extras", "min_maj_ver"=>1.0 },
  "riak_ts"             =>{ "s3_root"=>"riak_ts",              "min_maj_ver"=>1.2 },
}

# NOTE: All Hashes in this file use strings for keys, so we can correctly write
#       them to a YAML file after all data has been pulled from S3.


#####
# Rake Task Call
################
def generate_download_yaml()
  # The Hash we'll eventually write.
  download_info_hash = {}

  PROJECTS_TO_TRACK.each do |project_designation, project_meta|
    download_info_hash["#{project_designation}"] = version_hash = {}
    s3_root = project_meta["s3_root"]

    # For every project, pull the list of major version numbers (e.g. '2.0',
    # '2.1', etc.), and filter it based on that project's `min_maj_ver`.
    riak_major_versions = fetch_index_json("#{s3_root}")
                           .select { |k,v| v["type"] == "dir" }
                           .select { |k,v| k != "CURRENT" }
                           .select { |k,v| k.to_f >= project_meta["min_maj_ver"] }
                           .keys()
    riak_major_versions.each do |riak_major_version|
      # For every major version, pull the list of full version numbers.
      riak_versions = fetch_index_json("#{s3_root}/#{riak_major_version}")
                        .select { |k,v| v["type"] == "dir" }
                        .select { |k,v| k != "CURRENT" }
                        .keys()
      riak_versions.each do |riak_version|
        version_hash["#{riak_version}"] = os_list = []
        # Every full version directory will contain one directory per operating
        # system, and a source tarball. We want to first record information
        # regarding the source archive, then continue to iterate through the
        # operating systems.
        version_index_json = fetch_index_json("#{s3_root}/#{riak_major_version}/#{riak_version}")

        # Grab the source file list, and add it to download_info_hash (by way of
        # appending the source to the the os_list).
        source_maps = version_index_json.select { |k, v| v["type"] == "file"}
        source_maps.each do |k, v|
          file_info = {
            "file_name"=>k,
            "file_href"=>v["staticLink"],
            "file_size"=>v["size"]
          }
          os_list.push({"os"=>"source", "file_info"=>file_info})
        end

        # Move on to per-OS entries.
        operating_systems = version_index_json.select { |k,v| v["type"] == "dir" }
                              .select { |k,v| k != "CURRENT" }
                              .keys()
        operating_systems.each do |os|
          os_version_list = []
          os_list.push({"os"=>os, "versions"=>os_version_list})

          os_versions = fetch_index_json("#{s3_root}/#{riak_major_version}/#{riak_version}/#{os}")
                          .select { |k,v| v["type"] == "dir" }
                          .select { |k,v| k != "CURRENT" }
                          .keys()
          os_versions.each do |os_version|
            arch_list = []
            os_version_list.push({"version"=>os_version, "architectures"=>arch_list})

            package_maps = fetch_index_json("#{s3_root}/#{riak_major_version}/#{riak_version}/#{os}/#{os_version}")
                             .select { |k,v| v["type"] == "file" }
            # Filter out .sha files, and add each package to download_info_hash
            # (by way of appending the source to the the arch_list).
            package_maps.select { |k, v| k !~ /\.sha/ } .each do |k, v|
              file_info = {
                "file_name"=>k,
                "file_href"=>v["staticLink"],
                "file_size"=>v["size"]
              }
              if package_maps.has_key?("#{k}.sha")
                file_info["chksum_href"] = package_maps["#{k}.sha"]["staticLink"]
              end

              # attempt to extract the architecture from `k` (the file name)
              # (default to 'unknown')
              package_arch = 'unknown'
              if    k =~ /amd64/
                package_arch = 'amd64'
              elsif k =~ /x86_64/
                package_arch = 'x86_64'
              elsif k =~ /i386_64/
                package_arch = 'i386_64'
              elsif k =~ /i386/
                package_arch = 'i386'
              elsif k =~ /src/
                package_arch = 'source'
              elsif k =~ /\.txz/
                package_arch = 'txz'
              end

              arch_list.push({"arch"=>package_arch, "file_info"=>file_info})
            end
          end
        end
      end
    end
  end

  puts "Opening \"data/download_info.yaml\" for writing"
  File.open('data/download_info.yaml', 'w') do |f|
    f.write(download_info_hash.to_yaml)
  end

  puts ""
  puts "Download data generation complete!"
end


####
# Helper Functions
##################

# Reads the index.json file at a given path off of BASE_DOWNLOAD_URL, and
# extracts the JSON by stripping the leading HTML, the trailing `;`s, and by
# sending the rest through a JSON parser.
def fetch_index_json(relative_path)
  puts "Indexing \"#{relative_path}\"..."
  resp = Net::HTTP.get_response(BASE_URI.host, "#{BASE_URI.path}/#{relative_path}/index.json")
  json = resp.body.sub(/[^\{]+/, '').strip.sub(/;$/, '')
  JSON.parse(json)
end


# If this file is being run directly, go ahead and generate the download data.
if __FILE__ == $0
  generate_download_yaml()
end
