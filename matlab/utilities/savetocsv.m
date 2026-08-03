myStruct = Test_features;              % Replace with actual name
T = struct2table(myStruct);                 % Converts 1x59 struct to 59x141 table
writetable(T, 'test_data.csv');