"""
        PENBBScan2D(settings<:Dict, start<:Vector, step<:Vector, ends<:Vector, HolderName::String, time_per_point::Int64, motor)

Function to perform an automate scan in 2D (x,y axis). You'll have to connect to your motor before starting this function.
It will return a dictionary of the missed positions, if there are any.
...
# Arguments
- `settings<:Dict`: Dictionary containing all settings. Will be translated into NamedTuple for compatibility
- `start<:Vector`: Vector of start position e.g. [x_start,y_start] = [0.0,0.5]
- `step<:Vector`: Vector of step size e.g. [x_step,y_step] = [1.0,1.0]
- `ends<:Vector`: Vector of end position e.g. [x_end,y_end] = [90.0,90.0]
- `motor`: IO connection to the motorized stage
- `notebook::Bool=false`: Set to true if you take data using a Juypter notebook

...
"""
function PENBBScan2D(settings, start, step, ends, HolderName, motor, login_payload; notebook=false)
    
    # Timestamp for moved data
    timestamp = string(now())
    
    missed_positions = Dict()
    missed_positions["x"] = []
    missed_positions["y"] = []
    start_t = now()
    cur_dir = pwd()
    if start[1] < 0.0 || start[2] < 0.0 || ends[1] > 100.0 || ends[2] > 100.0
        @info("Error: value out of range: you have to use values in the range x[0.,10.], y[0.,10.]")
    else
        for i in collect(start[1]:step[1]:ends[1])
            XMoveMM(i,motor)
            current_x_pos = ""
            @showprogress "Performing y scan for x=$i " for j in collect(start[2]:step[2]:ends[2])
                #@info(string("Points skipped: ", length(missed_positions["x"])))
                @info("position: ",i,j)
                YMoveMM(j,motor)
                pos_x = PosX(motor)
                pos_y = PosY(motor)

                if 10 <= pos_x < 100
                    pos_x = string("0", pos_x)
                elseif pos_x < 10
                    pos_x = string("00", pos_x)
                else
                    pos_x = string(pos_x)
                end
                current_x_pos = pos_x
                if 10 <= pos_y < 100
                    pos_y = string("0", pos_y)
                elseif pos_y < 10
                    pos_y = string("00", pos_y)
                else
                    pos_y = string(pos_y)
                end
                

                #
                ## Sorting the output files in directories
                name_file = string("2D_PEN_Scan_Holder_",HolderName,"_x_",pos_x,"_y_",pos_y,"_of_",settings["measurement_time"],"_seconds")
                output_dir = settings["conv_data_dir"] * string("/", HolderName, "/x_",pos_x)
                
                #
                ## This conversion is just for compatibility
                settings_nt = (fadc = settings["fadc"],
                    output_basename = name_file,
                    data_dir = settings["data_dir"],
                    conv_data_dir = output_dir,
                    measurement_time = settings["measurement_time"],
                    number_of_measurements = 1,
                    channels = settings["channels"],
                    trigger_threshold = settings["trigger_threshold"],
                    trigger_pmt = settings["trigger_pmt"],
                    peakTime = settings["peakTime"],
                    gapTime = settings["gapTime"], 
                    nPreTrig = settings["nPreTrig"],
                    nSamples = settings["nSamples"],
                    saveEnergy = settings["saveEnergy"],
                    delete_dat = settings["delete_dat"],
                    h5_filesize_limit = settings["h5_filesize_limit"],
                    filter_faulty_events = settings["filter_faulty_events"],
                    coincidence_interval = settings["coincidence_interval"]
                );
                # println(name_file)
                
                # Measure until the data-taking succeeds
                done::Bool = false 
                retry_num = [0]

                while !done
                
                    ## Create asynchronous task for data taking
                    t = @async try take_struck_data(settings_nt, calibration_data=settings["calibration_data"])
                        catch e 
                        println("stopped on $e") 
                    end
                    
                    # Create timeout check
                    ts = 1
                    prog = Progress(3*settings["measurement_time"], "Time till skip:")
                    while istaskdone(t) == false && ts <= 3 * settings["measurement_time"]
                        # This loop will break when task t is compleded
                        # or when the time is over
                        sleep(1)
                        ts += 1
                        next!(prog)
                    end
                    
                    # After the loop has ended, this extra check will interrupt the data taking if needed
                    # For this, it throws and error to task t and kills all java processes (if scala process freezes)
                    if (istaskdone(t) == false || ts < settings["measurement_time"]) && retry_num[1] <= 3
                        @async Base.throwto(t, EOFError())
                        kill_all_java_processes(3 * settings["measurement_time"])
                        retry_num[1] += 1
                        if retry_num[1] > 3
                            push!(missed_positions["x"], i)
                            push!(missed_positions["y"], j)
                            open("missing_log_" * HolderName * ".json",  "w") do f
                                JSON.print(f, missed_positions, 4)
                            end
                            done = true
                        end
                    else # Data taking was successful
                        done = true 
                    end
                    
                    cd(cur_dir)
                    sleep(2)
                    
                    # Clear output to reduce memory taken by notebook
                    if notebook
                        IJulia.clear_output(true)
                    else
                        Base.run(`clear`)
                    end
                    
                end     
            end
            #
            ## Move x scan to ceph
            if settings["move_to_ceph"]
                @info("Moving data to ceph. Please wait")
                from_dir = joinpath(settings["conv_data_dir"], HolderName * "/x_" * current_x_pos)
                @info("Data will be moved from: " * from_dir)
                to_dir   = joinpath(settings["dir_on_ceph"], HolderName * "-" * timestamp * "/x_" * current_x_pos)
                @info("Data will be moved to: " * to_dir)
                !isdir(to_dir) ? mkpath(to_dir, mode= 0o777) : "dir exists"
                mv(from_dir, to_dir, force=true)    
                rm(settings["conv_data_dir"], recursive=true)
                try run(`chmod 777 -R $to_dir`) catch; end    
            end
        end
        @info("PEN BB 2D scan completed, see you soon!")
    end
    #@info("Missed positions are listed here:")
    return missed_positions
end
