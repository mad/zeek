##! This script provides the framework for software version detection and
##! parsing, but doesn't actually do any detection on it's own.  It relys on
##! other protocol specific scripts to parse out software from the protocols
##! that they analyze.  The entry point for providing new software detections
##! to this framework is through the :bro:id:`Software::found` function.

@load base/utils/directions-and-hosts
@load base/utils/numbers

module Software;

export {

	redef enum Log::ID += { SOFTWARE };

	type Type: enum {
		UNKNOWN,
		OPERATING_SYSTEM,
		DATABASE_SERVER,
		# There are a number of ways to detect printers on the 
		# network, we just need to codify them in a script and move
		# this out of here.  It isn't currently used for anything.
		PRINTER,
	};

	type Version: record {
		major:  count  &optional;  ##< Major version number
		minor:  count  &optional;  ##< Minor version number
		minor2: count  &optional;  ##< Minor subversion number
		addl:   string &optional;  ##< Additional version string (e.g. "beta42")
	} &log;

	type Info: record {
		## The time at which the software was first detected.
		ts:               time &log;
		## The IP address detected running the software.
		host:             addr &log;
		## The type of software detected (e.g. WEB_SERVER)
		software_type:    Type &log &default=UNKNOWN;
		## Name of the software (e.g. Apache)
		name:             string &log;
		## Version of the software
		version:          Version &log;
		## The full unparsed version string found because the version parsing 
		## doesn't work 100% reliably and this acts as a fall back in the logs.
		unparsed_version: string &log &optional;
		
		## This can indicate that this software being detected should
		## definitely be sent onward to the logging framework.  By 
		## default, only software that is "interesting" due to a change
		## in version or it being currently unknown is sent to the
		## logging framework.  This can be set to T to force the record
		## to be sent to the logging framework if some amount of this tracking
		## needs to happen in a specific way to the software.
		force_log:        bool &default=F;
	};
	
	## The hosts whose software should be detected and tracked.
	## Choices are: LOCAL_HOSTS, REMOTE_HOSTS, ALL_HOSTS, NO_HOSTS
	const asset_tracking = LOCAL_HOSTS &redef;
	
	
	## Other scripts should call this function when they detect software.
	## unparsed_version: This is the full string from which the
	##                   :bro:type:`Software::Info` was extracted.
	## Returns: T if the software was logged, F otherwise.
	global found: function(id: conn_id, info: Software::Info): bool;
	
	## This function can take many software version strings and parse them 
	## into a sensible :bro:type:`Software::Version` record.  There are 
	## still many cases where scripts may have to have their own specific 
	## version parsing though.
	global parse: function(unparsed_version: string,
	                       host: addr,
	                       software_type: Type): Info;
	
	## Compare two versions.
	## Returns:  -1 for v1 < v2, 0 for v1 == v2, 1 for v1 > v2.
	##           If the numerical version numbers match, the addl string
	##           is compared lexicographically.
	global cmp_versions: function(v1: Version, v2: Version): int;
	
	## This type represents a set of software.  It's used by the 
	## :bro:id:`tracked` variable to store all known pieces of software
	## for a particular host.  It's indexed with the name of a piece of 
	## software such as "Firefox" and it yields a 
	## :bro:type:`Software::Info` record with more information about the 
	## software.
	type SoftwareSet: table[string] of Info;
	
	## The set of software associated with an address.  Data expires from
	## this table after one day by default so that a detected piece of 
	## software will be logged once each day.
	global tracked: table[addr] of SoftwareSet 
		&create_expire=1day 
		&synchronized
		&redef;
	
	## This event can be handled to access the :bro:type:`Software::Info`
	## record as it is sent on to the logging framework.
	global log_software: event(rec: Info);
}

event bro_init()
	{
	Log::create_stream(SOFTWARE, [$columns=Info, $ev=log_software]);
	}

function parse_mozilla(unparsed_version: string, 
	                   host: addr, 
	                   software_type: Type): Info
	{
	local software_name = "<unknown browser>";
	local v: Version;
	local parts: table[count] of string;
	
	if ( /Opera [0-9\.]*$/ in unparsed_version )
		{
		software_name = "Opera";
		parts = split_all(unparsed_version, /Opera [0-9\.]*$/);
		if ( 2 in parts )
			v = parse(parts[2], host, software_type)$version;
		}
	else if ( /MSIE 7.*Trident\/4\.0/ in unparsed_version )
		{
		software_name = "MSIE"; 
		v = [$major=8,$minor=0];
		}
	else if ( / MSIE [0-9\.]*b?[0-9]*;/ in unparsed_version )
		{
		software_name = "MSIE";
		parts = split_all(unparsed_version, /MSIE [0-9\.]*b?[0-9]*/);
		if ( 2 in parts )
			v = parse(parts[2], host, software_type)$version;
		}
	else if ( /Version\/.*Safari\// in unparsed_version )
		{
		software_name = "Safari";
		parts = split_all(unparsed_version, /Version\/[0-9\.]*/);
		if ( 2 in parts )
			{
			v = parse(parts[2], host, software_type)$version;
			if ( / Mobile\/?.* Safari/ in unparsed_version )
				v$addl = "Mobile";
			}
		}
	else if ( /(Firefox|Netscape|Thunderbird)\/[0-9\.]*/ in unparsed_version )
		{
		parts = split_all(unparsed_version, /(Firefox|Netscape|Thunderbird)\/[0-9\.]*/);
		if ( 2 in parts )
			{
			local tmp_s = parse(parts[2], host, software_type);
			software_name = tmp_s$name;
			v = tmp_s$version;
			}
		}
	else if ( /Chrome\/.*Safari\// in unparsed_version )
		{
		software_name = "Chrome";
		parts = split_all(unparsed_version, /Chrome\/[0-9\.]*/);
		if ( 2 in parts )
			v = parse(parts[2], host, software_type)$version;
		}
	else if ( /^Opera\// in unparsed_version )
		{
		if ( /Opera M(ini|obi)\// in unparsed_version )
			{
			parts = split_all(unparsed_version, /Opera M(ini|obi)/);
			if ( 2 in parts )
				software_name = parts[2];
			parts = split_all(unparsed_version, /Version\/[0-9\.]*/);
			if ( 2 in parts )
				v = parse(parts[2], host, software_type)$version;
			else
				{
				parts = split_all(unparsed_version, /Opera Mini\/[0-9\.]*/);
				if ( 2 in parts )
					v = parse(parts[2], host, software_type)$version;
				}
			}
		else
			{
			software_name = "Opera";
			parts = split_all(unparsed_version, /Version\/[0-9\.]*/);
			if ( 2 in parts )
				v = parse(parts[2], host, software_type)$version;
			}
		}
	else if ( /AppleWebKit\/[0-9\.]*/ in unparsed_version )
		{
		software_name = "Unspecified WebKit";
		parts = split_all(unparsed_version, /AppleWebKit\/[0-9\.]*/);
		if ( 2 in parts )
			v = parse(parts[2], host, software_type)$version;
		}

	return [$ts=network_time(), $host=host, $name=software_name, $version=v,
	        $software_type=software_type, $unparsed_version=unparsed_version];
	}

# Don't even try to understand this now, just make sure the tests are 
# working.
function parse(unparsed_version: string,
	           host: addr,
	           software_type: Type): Info
	{
	local software_name = "<parse error>";
	local v: Version;
	
	# Parse browser-alike versions separately
	if ( /^(Mozilla|Opera)\/[0-9]\./ in unparsed_version )
		{
		return parse_mozilla(unparsed_version, host, software_type);
		}
	else
		{
		# The regular expression should match the complete version number
		# and software name.
		local version_parts = split_n(unparsed_version, /\/?( [\(])?v?[0-9\-\._, ]{2,}/, T, 1);
		if ( 1 in version_parts )
			{
			if ( /^\(/ in version_parts[1] )
				software_name = strip(sub(version_parts[1], /[\(]/, ""));
			else
				software_name = strip(version_parts[1]);
			}
		if ( |version_parts| >= 2 )
			{
			# Remove the name/version separator if it's left at the beginning
			# of the version number from the previous split_all.
			local sv = strip(version_parts[2]);
			if ( /^[\/\-\._v\(]/ in sv )
				sv = strip(sub(version_parts[2], /^\(?[\/\-\._v\(]/, ""));
			local version_numbers = split_n(sv, /[\-\._,\[\(\{ ]/, F, 3);
			if ( 4 in version_numbers && version_numbers[4] != "" )
				v$addl = strip(version_numbers[4]);
			else if ( 3 in version_parts && version_parts[3] != "" &&
			          version_parts[3] != ")" )
				{
				if ( /^[[:blank:]]*\([a-zA-Z0-9\-\._[:blank:]]*\)/ in version_parts[3] )
					{
					v$addl = split_n(version_parts[3], /[\(\)]/, F, 2)[2];
					}
				else
					{
					local vp = split_n(version_parts[3], /[\-\._,;\[\]\(\)\{\} ]/, F, 3);
					if ( |vp| >= 1 && vp[1] != "" )
						{
						v$addl = strip(vp[1]);
						}
					else if ( |vp| >= 2 && vp[2] != "" )
						{
						v$addl = strip(vp[2]);
						}
					else if ( |vp| >= 3 && vp[3] != "" )
						{
						v$addl = strip(vp[3]);
						}
					else
						{
						v$addl = strip(version_parts[3]);
						}
						
					}
				}
		
			if ( 3 in version_numbers && version_numbers[3] != "" )
				v$minor2 = extract_count(version_numbers[3]);
			if ( 2 in version_numbers && version_numbers[2] != "" )
				v$minor = extract_count(version_numbers[2]);
			if ( 1 in version_numbers && version_numbers[1] != "" )
				v$major = extract_count(version_numbers[1]);
			}
		}
	return [$ts=network_time(), $host=host, $name=software_name,
	        $version=v, $unparsed_version=unparsed_version,
	        $software_type=software_type];
	}


function cmp_versions(v1: Version, v2: Version): int
	{
	if ( v1?$major && v2?$major )
		{
		if ( v1$major < v2$major )
			return -1;
		if ( v1$major > v2$major )
			return 1;
		}
	else
		{
		if ( !v1?$major && !v2?$major )
			{ }
		else
			return v1?$major ? 1 : -1;
		}
		
	if ( v1?$minor && v2?$minor )
		{
		if ( v1$minor < v2$minor )
			return -1;
		if ( v1$minor > v2$minor )
			return 1;
		}
	else
		{
		if ( !v1?$minor && !v2?$minor )
			{ }
		else
			return v1?$minor ? 1 : -1;
		}
		
	if ( v1?$minor2 && v2?$minor2 )
		{
		if ( v1$minor2 < v2$minor2 )
			return -1;
		if ( v1$minor2 > v2$minor2 )
			return 1;
		}
	else
		{
		if ( !v1?$minor2 && !v2?$minor2 )
			{ }
		else
			return v1?$minor2 ? 1 : -1;
		}

	if ( v1?$addl && v2?$addl )
		return strcmp(v1$addl, v2$addl);
	else
		{
		if ( !v1?$addl && !v2?$addl )
			return 0;
		else
			return v1?$addl ? 1 : -1;
		}
	}

function software_endpoint_name(id: conn_id, host: addr): string
	{
	return fmt("%s %s", host, (host == id$orig_h ? "client" : "server"));
	}

# Convert a version into a string "a.b.c-x".
function software_fmt_version(v: Version): string
	{
	return fmt("%d.%d.%d%s", 
	           v?$major ? v$major : 0,
	           v?$minor ? v$minor : 0,
	           v?$minor2 ? v$minor2 : 0,
	           v?$addl ? fmt("-%s", v$addl) : "");
	}

# Convert a software into a string "name a.b.cx".
function software_fmt(i: Info): string
	{
	return fmt("%s %s", i$name, software_fmt_version(i$version));
	}

# Insert a mapping into the table
# Overides old entries for the same software and generates events if needed.
event software_register(id: conn_id, info: Info)
	{
	# Host already known?
	if ( info$host !in tracked )
		tracked[info$host] = table();

	local ts = tracked[info$host];
	# Software already registered for this host?  We don't want to endlessly
	# log the same thing.
	if ( info$name in ts )
		{
		local old = ts[info$name];
		
		# If the version hasn't changed, then we're just redetecting the
		# same thing, then we don't care.  This results in no extra logging.
		# But if the $force_log value is set then we'll continue.
		if ( ! info$force_log && cmp_versions(old$version, info$version) == 0 )
			return;
		}
	
	Log::write(SOFTWARE, info);
	ts[info$name] = info;
	}

function found(id: conn_id, info: Info): bool
	{
	if ( info$force_log || addr_matches_host(info$host, asset_tracking) )
		{
		event software_register(id, info);
		return T;
		}
	else
		return F;
	}
